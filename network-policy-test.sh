#!/bin/bash
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

CLUSTER_NAME=${CLUSTER_NAME:-kind}
SERVER_IMAGE=${SERVER_IMAGE:-couchbase/server:7.0.2}
SERVER_COUNT=${SERVER_COUNT:-3}
NAMESPACE=${NAMESPACE:-test}

if [[ "${CREATE_CLUSTER:-no}" == "yes" ]]; then
  # To use NetworkPolicy we need a custom CNI to support it.
  # Here we will use Calico.

  kind delete cluster --name="${CLUSTER_NAME}"
  kind create cluster --name="${CLUSTER_NAME}" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
 EphemeralContainers: true
networking:
  disableDefaultCNI: true    # disable kindnet
  podSubnet: 192.168.0.0/16  # set to Calico's default subnet
nodes:
  - role: control-plane
  - role: worker
EOF

  docker pull "${SERVER_IMAGE}"
  kind load docker-image "${SERVER_IMAGE}" --name="${CLUSTER_NAME}"

  kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
  kubectl -n kube-system set env daemonset/calico-node FELIX_IGNORELOOSERPF=true
  kubectl -n kube-system set env daemonset/calico-node FELIX_XDPENABLED=false
  # helm repo add projectcalico https://docs.projectcalico.org/charts || helm repo add projectcalico https://docs.projectcalico.org/charts
  # helm repo update
  # helm install calico projectcalico/tigera-operator --version v3.20.2 --wait

  echo "Waiting for Calico pods to start up..."
  until [[ $(kubectl get pods --namespace=kube-system --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c calico-node) -eq 2 ]]; do
      echo -n '.'
      sleep 2
  done
  echo "Calico pods ready to go"

  # Use a cluster DAC in a non-protected namespace to simplify webhook usage and we need the DAC service IP/port
  helm upgrade --install couchbase-dac couchbase/couchbase-operator --set cluster.image="$SERVER_IMAGE",install.couchbaseCluster=false,install.couchbaseOperator=false --namespace default --wait
else
  kubectl delete namespace test || true
fi

# We need the K8S server API endpoints so we can monitor and update
API_SERVER_IP=$(kubectl get endpoints --namespace default kubernetes --output=json|jq '.subsets[0].addresses[0].ip' -r)
API_SERVER_PORT=$(kubectl get endpoints --namespace default kubernetes --output=json|jq '.subsets[0].ports[0].port' -r)
echo "K8S API server endpoint is $API_SERVER_IP:$API_SERVER_PORT"

# We need the DAC endpoints for the operator to talk to
DAC_SERVER_IP=$(kubectl get service --namespace default couchbase-dac-couchbase-admission-controller --output=json|jq -r -c '.spec.clusterIP')
echo "DAC endpoint is $DAC_SERVER_IP:443"

# We have an issue with blocking comms to the DAC prior to running Helm so do afterwards
# Add network policy
# Default deny-all: https://raw.githubusercontent.com/kubernetes/website/main/content/en/examples/service/networking/network-policy-default-deny-all.yaml
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: $NAMESPACE
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  egress:
  # allow DNS resolution
  - ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-apiserver-and-dac
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: couchbase-operator
  policyTypes:
    - Egress
  egress:
    - {}
  # egress:
  # - to:
  #   - podSelector:
  #       matchLabels:
  #         app: couchbase
  # - ports:
  #   - port: $API_SERVER_PORT
  #     protocol: TCP
  #   to:
  #   - ipBlock:
  #       cidr: $API_SERVER_IP/32
  # - to:
  #   - ipBlock:
  #       cidr: $DAC_SERVER_IP/32
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: couchbase-namespace-policy
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      app: couchbase
  policyTypes:
    - Ingress
    - Egress
  # Allow traffic to/from the pods in the namespace
  ingress:
    - from:
      - podSelector: {}
  egress:
    - to:
      - podSelector: {}
EOF

# Add Couchbase via helm chart but without the DAC
helm repo add couchbase https://couchbase-partners.github.io/helm-charts/ || helm repo add couchbase https://couchbase-partners.github.io/helm-charts
helm repo update
helm upgrade --install couchbase couchbase/couchbase-operator --set cluster.image="$SERVER_IMAGE",install.admissionController=false --namespace "$NAMESPACE"

# Wait for deployment to complete, potentially a call to --wait may work with helm but it can be flakey
echo "Waiting for CB to start up..."
# The operator uses readiness gates to hold the containers until the cluster is actually ready to be used
until [[ $(kubectl get pods --namespace="$NAMESPACE" --field-selector=status.phase=Running --selector='app=couchbase' --no-headers 2>/dev/null |wc -l) -eq $SERVER_COUNT ]]; do
    echo -n '.'
    sleep 2
done
echo "CB configured and ready to go"

# Couchbase cluster is ready to go, not just started but configured.
# If you just run the container up then it marks itself ready as soon as it starts which is not entirely true.

