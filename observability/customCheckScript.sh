#!/bin/bash
set -eu
TEXTFILE_COLLECTOR_DIR=${TEXTFILE_COLLECTOR_DIR:-/custom-logs}
declare -a PORTS_TO_CHECK=(8091 8093 9100 12345)

apt-get update
apt install -y nmap

while true; do
    LOCAL_IP=$(hostname -I)
    rm -f "${OUTPUT_DIR}/couchbase_portcheck.prom"

    for IP in $(seq 1 15); do
        HOST=${LOCAL_IP%.*}.${IP}
        for PORT in "${PORTS_TO_CHECK[@]}"; do
            echo "Checking ${HOST}:${PORT}"
            IS_UP=0
            if nmap "${HOST}" -p "${PORT}" --open 2>/dev/null | grep -q "Host is up"; then
                IS_UP=1
            fi
            echo "${HOST}_port_${PORT}_open ${IS_UP}" | tr ./ _ >> "${TEXTFILE_COLLECTOR_DIR}/couchbase_portcheck.prom.$$"
        done
    done
    # Prevent partial metrics appearing just as we scrape
    mv -f "${TEXTFILE_COLLECTOR_DIR}/couchbase_portcheck.prom.$$" "${TEXTFILE_COLLECTOR_DIR}/couchbase_portcheck.prom"
    cat "${TEXTFILE_COLLECTOR_DIR}/couchbase_portcheck.prom"
    sleep 30
done