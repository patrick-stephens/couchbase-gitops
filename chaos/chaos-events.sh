#!/bin/bash
set -eux

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-no}
REBUILD_ALL=${REBUILD_ALL:-yes}
SERVER_COUNT=${SERVER_COUNT:-3}
CLUSTER_NAME=${CLUSTER:-chaos-test}

SERVER_COUNT=${SERVER_COUNT} SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION} CLUSTER_NAME=${CLUSTER_NAME} REBUILD_ALL=${REBUILD_ALL} /bin/bash "${SCRIPT_DIR}/../createCluster.sh"

# https://chaos-mesh.org/docs/get_started/get_started_on_kind
kubectl delete ns chaos-testing || true
curl -sSL https://mirrors.chaos-mesh.org/v1.2.0/install.sh | bash -s -- --local kind

kubectl get pods --namespace chaos-testing -l app.kubernetes.io/instance=chaos-mesh

kubectl apply -f "${SCRIPT_DIR}/jaeger.yaml"

kubectl create clusterrolebinding default-admin --clusterrole cluster-admin --serviceaccount=default:default
kubectl apply -f "${SCRIPT_DIR}/kspan.yaml"

#kubectl port-forward jaeger-6fc5fcb56c-qr7z4 16686:16686
#kubectl port-forward -n chaos-testing svc/chaos-dashboard 2333:2333
