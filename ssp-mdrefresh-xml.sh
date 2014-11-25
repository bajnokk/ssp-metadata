#!/bin/bash
# Source: https://github.com/bajnokk/ssp-metadata

### SimpleSAMLphp configuration
#
# Base directory of the parsed metadata files
# The location of the individual files will be at
# $metadatadir/metarefresh-$metadata
metadatadir=/var/simplesamlphp/metadata
#
# Metarefresh script
metarefresh=/var/simplesamlphp/modules/metarefresh/bin/metarefresh.php

### Federation configuration
#
# Sets to consume, for example:
# metadata_sets=(pte href edugain)
metadata_sets=(href)
#
# Federation signing certificate fingerprint
fingerprint=FE:AE:0B:E8:FB:59:ED:F7:CB:7F:69:DF:19:4F:8B:6D:C7:F6:96:66
#
# Metadata distribution point, __MDSET__ will be replaced with the actual metadata set name
metadata_url=https://metadata.eduid.hu/current/__MDSET__.xml

### End of configuration section

set -e
SCRIPTNAME=$(basename $0)
LOCK_DIR="/var/lock/${SCRIPTNAME}"
PIDFILE="${LOCK_DIR}/PID"
 
function lock {
  if mkdir $LOCK_DIR 2>/dev/null; then
    echo $$ > $PIDFILE
  elif kill -0 $(cat $PIDFILE) 2>/dev/null; then
    echo "Another instance of $SCRIPTNAME is running with PID $(cat $PIDFILE), aborting" 1>&2
    exit 4
  else
    echo "Removing stale lock file, PID $(cat $PIDFILE) seems to be dead" 1>&2
    echo $$ > $PIDFILE
  fi
  if [[ "$$" != "$(cat $PIDFILE)" ]]; then
    echo "Locking failed" 1>&2
    exit 4
  fi
}

function unlock {
  rm -r $LOCK_DIR
}

startregexp="/\* The following data should be added to .*/([^/]+\.php)"
endregexp="/\* End of data which should be added to.*/([^/]+\.php)"

lock

for metadata in ${metadata_sets[*]}; do
  downloadfile=$(mktemp)
  processdir="$metadatadir/metarefresh-$metadata"
  processfile=""
  validation_status=unknown
  url=${metadata_url/__MDSET__/$metadata}
  if [ ! -d $processdir ]; then
    echo "Error, expected output directory ($processdir) doesn't exist!" 1>&2
    exit 2
  fi
  wget -nv -q $url -O $downloadfile
  # For the actual command, see the end of the loop
  while IFS= read -r line; do
    # XXX: metarefresh terminates successfully even if the signature validation
    # has failed, but in this case the output is empty.
    if [[ $line =~ $startregexp ]]; then
      processfile=$(mktemp --tmpdir=$processdir $metadata.XXXXX)
      # If we can loop over metarefresh output, we can assume it has been validated
      validation_status=validated
      echo "<?php" >$processfile
    elif [[ $line =~ $endregexp ]]; then
      if [ -s $processfile ]; then
        chmod 644 "$processfile" # Metadata is public, add read permissions to others
        mv "$processfile" "$processdir/${BASH_REMATCH[1]}"
      else
        echo "Will not overwrite $processdir/${BASH_REMATCH[1]} with an empty file" 1>&2
      fi
    else
      if [ -f $processfile ]; then
        echo "$line" >> $processfile
      else
        if [[ $line =~ ^$ ]]; then
          continue
        else
          echo "Error parsing metarefresh output, cautiously avoid writing into nowhere" 1>&2
         exit 3
        fi
      fi
    fi
  done < <(nice php $metarefresh --stdout --validate-fingerprint=$fingerprint $downloadfile)
  if [[ "$validation_status" == "unknown" ]]; then
    echo "Error validating metadata: $url, aborting." 1>&2
    exit 5
  fi
  rm $downloadfile
done

unlock
