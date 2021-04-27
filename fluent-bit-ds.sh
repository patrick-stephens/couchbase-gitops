#!/bin/bash
set -eu

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-no}
REBUILD_ALL=${REBUILD_ALL:-yes}
SERVER_COUNT=${SERVER_COUNT:-1}
CLUSTER_NAME=${CLUSTER:-fluentbit-ds}

SERVER_COUNT=${SERVER_COUNT} SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION} CLUSTER_NAME=${CLUSTER_NAME} REBUILD_ALL=${REBUILD_ALL} /bin/bash "${SCRIPT_DIR}/createCluster.sh"

helm repo add fluent https://fluent.github.io/helm-charts
helm upgrade --install fluent-bit fluent/fluent-bit -f fluent-bit-ds-config.yaml

# helm repo add grafana https://grafana.github.io/helm-charts
# helm repo update
# helm upgrade --install loki loki/loki-stack \
#   --set grafana.image.tag=7.5.2,fluent-bit.enabled=true,promtail.enabled=false,grafana.enabled=true,prometheus.enabled=true,prometheus.alertmanager.persistentVolume.enabled=false,prometheus.server.persistentVolume.enabled=false
