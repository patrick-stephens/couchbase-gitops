#!/bin/bash
set

for FILE in "$CONFIG_DIR"/* ; do
    echo "$FILE:"
    cat "$FILE"
done

echo "Waiting for $DYNAMIC_CONFIG_DIR/$MY_POD_NAME.conf..."
until [[ -f "$DYNAMIC_CONFIG_DIR/$MY_POD_NAME.conf" ]] ; do
    sleep 1
    echo -n "."
done
echo " completed."

cat "$DYNAMIC_CONFIG_DIR/$MY_POD_NAME.conf"

# shellcheck disable=SC1090
source "$DYNAMIC_CONFIG_DIR/$MY_POD_NAME.conf"
echo "Ordinal: ${CBES_ORDINAL}"

sleep 3600
# TODO: switch to a watcher process that relaunches on config file change