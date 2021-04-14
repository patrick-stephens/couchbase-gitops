#!/bin/bash
set -eux

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
DAC_IMAGE=couchbaseqe/couchbase-operator-admission:b771f1c6a6a94547e1da6823678d5d0873c51005
OP_IMAGE=couchbaseqe/couchbase-operator:b771f1c6a6a94547e1da6823678d5d0873c51005
SERVER_IMAGE=${SERVER_IMAGE:-couchbase/server:6.6.1}

# Find the relevant git repos locally
OPERATOR_REPO_DIR=$(find $SCRIPT_DIR/../../ -type d -name "couchbase-operator" -print0)

#gcloud beta container --project "couchbase-engineering" clusters create-auto "autopilot-logging-test" --region "us-east1" --release-channel "regular" --network "projects/couchbase-engineering/global/networks/default" --subnetwork "projects/couchbase-engineering/regions/us-east1/subnetworks/default" --cluster-ipv4-cidr "/17" --services-ipv4-cidr "/22"
gcloud container clusters get-credentials autopilot-logging-ci --region us-east1 --project couchbase-engineering
kubectl create clusterrolebinding patrick-stephens-admin-binding --clusterrole cluster-admin --user patrick.stephens@couchbase.com

# Delete
"${OPERATOR_REPO_DIR}/build/bin/cbopcfg" generate operator | kubectl delete -f -
"${OPERATOR_REPO_DIR}/build/bin/cbopcfg" generate admission --with-mutation=false | kubectl delete -f - 
kubectl delete -f "${OPERATOR_REPO_DIR}/example/crd.yaml"

# Install CRD, DAC and operator
kubectl create -f "${OPERATOR_REPO_DIR}/example/crd.yaml"
"${OPERATOR_REPO_DIR}/build/bin/cbopcfg" create admission --replicas=3 --with-resources --with-mutation=false --image="${DAC_IMAGE}" --log-level=debug
"${OPERATOR_REPO_DIR}/build/bin/cbopcfg" create operator --with-resources --image="${OP_IMAGE}" --log-level=debug

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace logging
#do we want to remove persistence in case it fills up??!
helm upgrade --debug --install loki --namespace=logging grafana/loki-stack --set grafana.enabled=true,prometheus.enabled=false,loki.persistence.enabled=true,loki.persistence.storageClassName=standard,loki.persistence.size=5Gi,promtail.enabled=false
helm upgrade --debug --install loki grafana/loki-stack --set grafana.enabled=true,prometheus.enabled=false,promtail.enabled=false

# Wait for deployment to complete
echo "Waiting for Grafana to start up..."
until kubectl rollout status -n logging deployment/loki-grafana; do
    echo -n '.'
    sleep 2
done
echo "Grafana running"

kubectl get secret loki-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo

# Need to wait for operator and DAC to start up
echo "Waiting for DAC to complete..."
until kubectl rollout status deployment couchbase-operator-admission; do
    echo -n "."
    sleep 2
done
echo " done"
echo "Waiting for operator to complete..."
until kubectl rollout status deployment couchbase-operator; do
    echo -n "."
    sleep 2
done
echo " done"

kubectl create secret generic custom-config --from-file=fluent-bit.conf
kubectl apply -f "${SCRIPT_DIR}/custom-log-cluster.yaml"
#kubectl apply -f "${SCRIPT_DIR}/cluster-crd.yaml"

# Wait for deployment to complete
echo "Waiting for CB to start up..."
until [[ $(kubectl get pods --field-selector=status.phase=Running --selector='app=couchbase' --no-headers 2>/dev/null |wc -l) -eq 3 ]]; do
    echo -n '.'
    sleep 2
done
echo "CB started"

kubectl apply -f "${OPERATOR_REPO_DIR}/example/tools/pillowfight-data-loader.yaml"

