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

# Simple script to provision a Kubernetes cluster using KIND: https://kind.sigs.k8s.io/
# It then spins up a Couchbase Server cluster on it using Helm: https://helm.sh/
# To use, need Docker (or a container runtime) installed plus kubectl, KIND & Helm.
set -eu

# In case you want a different name
CLUSTER_NAME=${CLUSTER_NAME:-couchbase-test}
# The server container image to use
SERVER_IMAGE=${SERVER_IMAGE:-couchbase/server:7.0.0}

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

# Speed up deployment by pre-loading the server image
docker pull "${SERVER_IMAGE}"
kind load docker-image "${SERVER_IMAGE}" --name="${CLUSTER_NAME}"

# Add Couchbase via helm chart
helm repo add couchbase https://couchbase-partners.github.io/helm-charts/ || helm repo add couchbase https://couchbase-partners.github.io/helm-charts
# Ensure we update the repo (may have added it years ago!)
helm repo update
# Always installs the latest version, can be pinned with --version X
helm upgrade --install couchbase couchbase/couchbase-operator --set cluster.image="${SERVER_IMAGE}"

# Wait for deployment to complete, potentially a call to --wait may work with helm but it can be flakey
echo "Waiting for CB to start up..."
# The operator uses readiness gates to hold the containers until the cluster is actually ready to be used
until [[ $(kubectl get pods --field-selector=status.phase=Running --selector='app=couchbase' --no-headers 2>/dev/null |wc -l) -eq 3 ]]; do
    echo -n '.'
    sleep 2
done
echo "CB configured and ready to go"

# Couchbase cluster is ready to go, not just started but configured.
# If you just run the container up then it marks itself ready as soon as it starts which is not entirely true.
