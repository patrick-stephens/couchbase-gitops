#!/bin/bash
# Assume helm, kubectl and kind are installed
set -eu
NAMESPACE=${NAMESPACE:-test}
SERVER_COUNT=${SERVER_COUNT:-3}
CONFIG_DIR=$(mktemp -d)
CLUSTER_NAME=${CLUSTER_NAME:-test-istio}
CLUSTER_CONFIG="${CONFIG_DIR}/multinode-cluster-conf.yaml"

# Create our cluster
cat << EOF > "${CLUSTER_CONFIG}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
EOF

for i in $(seq "$SERVER_COUNT"); do
      echo "Adding worker $i"
      cat << EOF >> "${CLUSTER_CONFIG}"
- role: worker
EOF
done

kind delete cluster --name="${CLUSTER_NAME}" && echo "Deleted old kind cluster, creating a new one..."
kind create cluster --name="${CLUSTER_NAME}" --config="${CLUSTER_CONFIG}"

# We load the images here to make sure we do not hit rate limits when run in a loop for CI
# These images should cover 2.1 and 2.2 and Istio 1.10.1
declare -a IMAGES_REQUIRED=("docker.io/istio/proxyv2:1.10.1"
"couchbase/server:6.6.0"
"couchbase/server:6.6.2"
"couchbase/operator:2.2.0"
"couchbase/admission-controller:2.2.0"
"couchbase/operator:2.1.0"
"couchbase/admission-controller:2.1.0"
)
for i in "${IMAGES_REQUIRED[@]}"
do
   docker pull "$i"
   kind load docker-image "$i" --name="${CLUSTER_NAME}"
done

# Add Istio
TEMPDIR=$(mktemp -d)
pushd "$TEMPDIR"
curl -L https://istio.io/downloadIstio | sh -
pushd istio-1.10.1/bin

./istioctl install --set profile=default --skip-confirmation
# https://istio.io/latest/docs/tasks/security/authentication/authn-policy/#globally-enabling-istio-mutual-tls-in-strict-mode
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    istio-injection: enabled
---
apiVersion: "security.istio.io/v1beta1"
kind: "PeerAuthentication"
metadata:
  name: "peer-authentication-cluster"
  namespace: $NAMESPACE
spec:
  mtls:
    mode: STRICT
---
apiVersion: "security.istio.io/v1beta1"
kind: "PeerAuthentication"
metadata:
  name: "peer-authentication-dac"
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: couchbase-admission-controller
  mtls:
    mode: PERMISSIVE
---
apiVersion: "security.istio.io/v1beta1"
kind: "PeerAuthentication"
metadata:
  name: "peer-authentication-metrics"
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      app: couchbase
  portLevelMtls:
    9091:
      mode: PERMISSIVE
---
EOF

popd
popd
rm -rf "$TEMPDIR"

# Add Couchbase via helm chart
helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
helm repo update
helm upgrade --install -n $NAMESPACE test1 couchbase/couchbase-operator #--version 2.1.0

# Wait for 3 servers to come up
echo "Waiting for CB to start up..."
until [[ $(kubectl get pods -n $NAMESPACE --field-selector=status.phase=Running --selector='app=couchbase' --no-headers 2>/dev/null |wc -l) -eq 3 ]]; do
    echo -n '.'
    sleep 2
done
echo "CB started"

