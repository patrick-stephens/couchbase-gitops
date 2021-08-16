#!/bin/bash
# Copyright 2021 Couchbase, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file  except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the  License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu

SERVER_IMAGE=${SERVER_IMAGE:-couchbase/server:6.6.2}
PILLOWFIGHT_USER=${PILLOWFIGHT_USER:-Administrator}
PILLOWFIGHT_PWD=${PILLOWFIGHT_PWD:-WnB3VnRB}

kubectl delete job/cb-workload-gen || true

# cat << EOF | kubectl apply -f -
# ---
# apiVersion: batch/v1
# kind: Job
# metadata:
#   name: cb-workload-gen
# spec:
#   template:
#     spec:
#       containers:
#       - name: doc-loader
#         image: $SERVER_IMAGE
#         command: ["/opt/couchbase/bin/cbc-pillowfight", "-U", "http://couchbase-couchbase-cluster-srv/default", "-v", "--ssl=no_verify", "-u", "$PILLOWFIGHT_USER", "-p", "$PILLOWFIGHT_PWD", "-I", "10000", "--json", "-M", "500", "-y", "-t", "4", "-D", "operation_timeout=60000"]
#       restartPolicy: Never
# EOF

cat << EOF | kubectl apply -f -
---
apiVersion: batch/v1
kind: Job
metadata:
  name: cb-workload-gen
spec:
  template:
    spec:
      containers:
      - name: doc-loader
        image: $SERVER_IMAGE
        command: ["/opt/couchbase/bin/cbworkloadgen", "-n","couchbase-couchbase-cluster-0000.couchbase-couchbase-cluster.default.svc:8091", "-u", "$PILLOWFIGHT_USER", "-p", "$PILLOWFIGHT_PWD", "-t", "4", "-r", ".7", "-j", "-s", "1024","--prefix=wrote-a","-i", "2000000", "-b", "default"]
      restartPolicy: Never
EOF