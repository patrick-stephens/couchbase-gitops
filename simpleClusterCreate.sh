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

CLUSTER_NAME=${CLUSTER_NAME:-couchbase-test}
SERVER_IMAGE=${SERVER_IMAGE:-couchbase/server:6.6.2}

# Delete the old cluster
kind delete cluster --name="${CLUSTER_NAME}"

# Set up KIND cluster with 3 worker nodes
CLUSTER_CONFIG=$(mktemp)
cat << EOF > "${CLUSTER_CONFIG}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
EOF

# Create the new cluster
kind create cluster --name="${CLUSTER_NAME}" --config="${CLUSTER_CONFIG}"
rm -f "${CLUSTER_CONFIG}"

# Add Couchbase via helm chart
helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
helm repo update
helm upgrade --install couchbase couchbase/couchbase-operator --set cluster.image="${SERVER_IMAGE}"

# Wait for deployment to complete
echo "Waiting for CB to start up..."
until [[ $(kubectl get pods --field-selector=status.phase=Running --selector='app=couchbase' --no-headers 2>/dev/null |wc -l) -eq 3 ]]; do
    echo -n '.'
    sleep 2
done
echo "CB started"
