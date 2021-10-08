#!/bin/bash
set

echo "Waiting for cbes-informer/$MY_POD_NAME.conf..."
until curl --silent --fail "cbes-informer/$MY_POD_NAME.conf" --output "/tmp/$MY_POD_NAME.conf" ; do
    sleep 1
    echo -n "."
done
echo " completed."

for FILE in "$CONFIG_DIR"/* ; do
    echo "$FILE:"
    cat "$FILE"
done
cat "/tmp/$MY_POD_NAME.conf"

# shellcheck disable=SC1090
source "/tmp/$MY_POD_NAME.conf"
echo "Ordinal: ${CBES_ORDINAL}"

sleep 3600