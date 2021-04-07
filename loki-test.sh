#!/bin/bash
set -eu

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-no}
REBUILD_ALL=${REBUILD_ALL:-yes}
SERVER_COUNT=${SERVER_COUNT:-3}
CLUSTER_NAME=${CLUSTER:-loki-test}

SERVER_COUNT=${SERVER_COUNT} SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION} CLUSTER_NAME=${CLUSTER_NAME} REBUILD_ALL=${REBUILD_ALL} /bin/bash "${SCRIPT_DIR}/createCluster.sh"

DEPLOY_CLOKI=${DEPLOY_CLOKI:-yes}

if [[ "${DEPLOY_CLOKI}" == "yes" ]]; then
  kubectl delete namespace logging || true

  # Install Helm locally
  wget -q -O- https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
  # Install Grafana, Loki, etc. using Helm
  helm repo add grafana https://grafana.github.io/helm-charts
  kubectl create namespace logging
  helm upgrade --install loki --namespace=logging grafana/loki-stack \
    --set fluent-bit.enabled=false,promtail.enabled=true,grafana.enabled=true,prometheus.enabled=true,prometheus.alertmanager.persistentVolume.enabled=false,prometheus.server.persistentVolume.enabled=false,grafana.image.tag="7.5.2"

  # Wait for deployment to complete
  echo "Waiting for Grafana to start up..."
  until kubectl rollout status -n logging deployment/loki-grafana; do
    echo -n '.'
    sleep 2
  done
  echo "Grafana running"

  kubectl get secret --namespace logging loki-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
  kubectl port-forward --namespace logging service/loki-grafana 3000:80
fi