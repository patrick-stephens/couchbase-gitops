#!/bin/bash
set -ex

FLUENT_BIT_HOME=${FLUENT_BIT_HOME:-/fluent-bit}
"${FLUENT_BIT_HOME}/bin/fluent-bit" -c "${FLUENT_BIT_HOME}/etc/fluent-bit.conf" &

/opt/couchbase/start-cb.sh && sleep 20