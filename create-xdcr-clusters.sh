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

CLUSTER_NAME=${CLUSTER_NAME:-kind}
SERVER_IMAGE=${SERVER_IMAGE:-couchbase/server:7.0.2}
SERVER_COUNT=${SERVER_COUNT:-3}

kind delete cluster --name="${CLUSTER_NAME}"
kind create cluster --name="${CLUSTER_NAME}" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
EOF

docker pull "${SERVER_IMAGE}"
kind load docker-image "${SERVER_IMAGE}" --name="${CLUSTER_NAME}"

if [[ ${USE_ISTIO:-yes} == "yes" ]]; then
  # Add Istio for local and remote namespaces in STRICT mode with injection enabled
  TEMPDIR=$(mktemp -d)
  pushd "$TEMPDIR"
    curl -L https://istio.io/downloadIstio | sh -
    pushd istio-*/bin
      ./istioctl install --set profile=default --skip-confirmation \
        --set values.global.istiod.enableAnalysis=true \
        --set meshConfig.accessLogFile=/dev/stdout \
        --set values.global.proxy.privileged=true
    popd
  popd
  rm -rf "$TEMPDIR"
fi

LOCAL_NAMESPACE_INJECTION=${LOCAL_NAMESPACE_INJECTION:-enabled}
REMOTE_NAMESPACE_INJECTION=${REMOTE_NAMESPACE_INJECTION:-enabled}

# https://istio.io/latest/docs/tasks/security/authentication/authn-policy/#globally-enabling-istio-mutual-tls-in-strict-mode
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: local
  labels:
    istio-injection: $LOCAL_NAMESPACE_INJECTION
---
apiVersion: v1
kind: Namespace
metadata:
  name: remote
  labels:
    istio-injection: $REMOTE_NAMESPACE_INJECTION
---
EOF

if [[ ${USE_STRICT_MODE:-yes} == "yes" ]]; then
  kubectl apply -f - <<EOF
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: peer-authentication-cluster
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: peer-authentication-dac
  namespace: default
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: couchbase-admission-controller
  mtls:
    mode: PERMISSIVE
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: peer-authentication-metrics
  namespace: istio-system
spec:
  selector:
    matchLabels:
      app: couchbase
  portLevelMtls:
    9091:
      mode: PERMISSIVE
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: peer-authentication-certification
  namespace: default
spec:
  selector:
    matchLabels:
      app: certification
  mtls:
    mode: STRICT
---
EOF
fi

helm repo add couchbase https://couchbase-partners.github.io/helm-charts/ || helm repo add couchbase https://couchbase-partners.github.io/helm-charts
helm repo update

helm upgrade --install daconly couchbase/couchbase-operator --set install.admissionController=true,install.couchbaseOperator=false,install.couchbaseCluster=false
until [[ $(kubectl get pods --field-selector=status.phase=Running --selector='app.kubernetes.io/name=couchbase-admission-controller' --no-headers 2>/dev/null |wc -l) -eq 1 ]]; do
    echo -n '.'
    sleep 2
done

HELM_CONFIG=$(mktemp)
echo "Using Helm config file: $HELM_CONFIG"
cat << EOF > "${HELM_CONFIG}"
install:
    admissionController: false
cluster:
    image: ${SERVER_IMAGE}
    networking:
        networkPlatform: Istio
    servers:
        default:
            size: ${SERVER_COUNT}
    security:
        password: "Password"
EOF

helm upgrade --install remote couchbase/couchbase-operator --values="${HELM_CONFIG}" --namespace remote

until [[ $(kubectl --namespace remote get pods --field-selector=status.phase=Running --selector='app=couchbase' --no-headers 2>/dev/null |wc -l) -eq $SERVER_COUNT ]]; do
    echo -n '.'
    sleep 2
done

# Sleep for at least 1 reconcile loop to allow for cluster ID update
sleep 20
CLUSTER_ID=$(kubectl get cbc --namespace remote remote-couchbase-cluster -o template --template='{{.status.clusterId}}')
# IP based addressing fails, service based addressing does
# Get a node IP (worker) and node port for the remote cluster
REMOTE_NODE_PORT=$(kubectl --namespace remote get svc remote-couchbase-cluster-ui -o json | jq '.spec.ports[0].nodePort')
REMOTE_NODE_IP=$(kubectl get nodes -o json| jq -c '.items[1].status.addresses[0].address'|tr -d '"')
REMOTE_CLUSTER_HOSTNAME="couchbase://$REMOTE_NODE_IP:$REMOTE_NODE_PORT?network=external"

if [[ ${USE_DNS:-no} == "yes" ]]; then
  REMOTE_CLUSTER_HOSTNAME="couchbase://remote-couchbase-cluster-srv.remote?network=external" # Works
fi

echo "Using: $REMOTE_CLUSTER_HOSTNAME"

cat << EOF >> "${HELM_CONFIG}"
    xdcr:
        managed: true
        remoteClusters:
            - authenticationSecret: auth-local-couchbase-cluster
              hostname: $REMOTE_CLUSTER_HOSTNAME
              name: remote-couchbase-cluster
              uuid: ${CLUSTER_ID}
EOF

helm upgrade --install local couchbase/couchbase-operator --values="${HELM_CONFIG}" --namespace local

# Wait for deployment to complete, the --wait flag does not work for this.
echo "Waiting for CB to start up..."
# The operator uses readiness gates to hold the containers until the cluster is actually ready to be used
until [[ $(kubectl --namespace local get pods --field-selector=status.phase=Running --selector='app=couchbase' --no-headers 2>/dev/null |wc -l) -eq $SERVER_COUNT ]]; do
    echo -n '.'
    sleep 2
done

echo "CB configured and ready to go"

cat << EOF | kubectl apply -f -
apiVersion: couchbase.com/v2
kind: CouchbaseReplication
metadata:
  name: replicate-default-buckets
  namespace: local
spec:
  bucket: default
  remoteBucket: default
EOF

echo "Added bucket replication"

kubectl logs -f deployment/local-couchbase-operator  --namespace local

# kubectl port-forward -n local svc/local-couchbase-cluster-ui 8091:8091

# cat << EOF | kubectl apply -f -
# ---
# apiVersion: batch/v1
# kind: Job
# metadata:
#   name: cb-workload-gen
#   namespace: local
# spec:
#   template:
#     spec:
#       containers:
#       - name: doc-loader
#         image: couchbase/server:7.0.2
#         command: ["/opt/couchbase/bin/cbworkloadgen", "-n","local-couchbase-cluster-0000.local-couchbase-cluster.local.svc:8091", "-u", "Administrator", "-p", "Password", "-t", "4", "-r", ".7", "-j", "-s", "1024","--prefix=wrote-a","-i", "100", "-b", "default"]
#       restartPolicy: Never
# EOF