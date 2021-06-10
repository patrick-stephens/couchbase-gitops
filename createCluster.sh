#!/bin/bash
set -eux

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

CONFIG_DIR=$(mktemp -d)
CLUSTER_NAME=${CLUSTER_NAME:-logshipper-test}
CLUSTER_CONFIG="${CONFIG_DIR}/multinode-cluster-conf.yaml"

SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-no}
REBUILD_ALL=${REBUILD_ALL:-yes}
CUSTOM_CB_CONFIG=${CUSTOM_CB_CONFIG:-no}

# Find the relevant git repos locally
OPERATOR_REPO_DIR=$(find $SCRIPT_DIR/../ -type d -wholename '*couchbase/couchbase-operator' -print0)
LOGSHIPPER_REPO_DIR=$(find $SCRIPT_DIR/../ -type d -name "couchbase-fluent-bit" -print0)

DOCKER_TAG=${DOCKER_TAG:-v1}
SERVER_IMAGE=${SERVER_IMAGE:-couchbase/server:6.6.2}
SERVER_COUNT=${SERVER_COUNT:-3}
set +x

if [[ "${REBUILD_ALL}" == "yes" ]]; then
  echo "Full rebuild"
  SKIP_CLUSTER_CREATION=no

  pushd "${LOGSHIPPER_REPO_DIR}"
  make clean build container
  popd

  pushd "${OPERATOR_REPO_DIR}"
  make && make container
  popd
fi

if [[ "${SKIP_CLUSTER_CREATION}" != "yes" ]]; then
  echo "Recreating full cluster"

  # Simple script to deal with running up a test cluster for KIND for developing logging updates for.
  cat << EOF > "${CLUSTER_CONFIG}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
 EphemeralContainers: true
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
  echo "$(date) waiting for cluster..."
  until kubectl cluster-info;  do
      echo -n "."
      sleep 2
  done
  echo -n " done"

  # Check we can use the storage ok
  if ! kubectl get sc standard -o yaml|grep -q "volumeBindingMode: WaitForFirstConsumer"; then
      echo "Standard storage class is not lazy binding so needs manual set up"
      exit 1
  fi

  # Ensure we have everything we need
  kind load docker-image "couchbase/couchbase-operator:${DOCKER_TAG}" --name="${CLUSTER_NAME}"
  kind load docker-image "couchbase/couchbase-operator-admission:${DOCKER_TAG}" --name="${CLUSTER_NAME}"
  kind load docker-image "couchbase/fluent-bit:${DOCKER_TAG}" --name="${CLUSTER_NAME}"

  # Not strictly required but improves caching performance
  docker pull "${SERVER_IMAGE}"
  kind load docker-image "${SERVER_IMAGE}" --name="${CLUSTER_NAME}"
  # It also slows down everything to allow the cluster to come up fully

  rm -rf "${CONFIG_DIR}"

  # Install CRD, DAC and operator
  kubectl create -f "${OPERATOR_REPO_DIR}/example/crd.yaml"
  "${OPERATOR_REPO_DIR}/build/bin/cbopcfg" create admission --image="couchbase/couchbase-operator-admission:${DOCKER_TAG}" --log-level=debug
  "${OPERATOR_REPO_DIR}/build/bin/cbopcfg" create operator --image="couchbase/couchbase-operator:${DOCKER_TAG}" --log-level=debug

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

if [[ "${CUSTOM_CB_CONFIG}" != "yes" ]]; then
    # Now create a cluster using the specified config
    cat << __CLUSTER_CONFIG_EOF__ | kubectl apply -f -
  apiVersion: v1
  kind: Secret
  metadata:
    name: cb-example-auth
  type: Opaque
  data:
    username: QWRtaW5pc3RyYXRvcg== # Administrator
    password: cGFzc3dvcmQ=         # password
  ---
  apiVersion: couchbase.com/v2
  kind: CouchbaseEphemeralBucket
  metadata:
    name: default
  ---
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-example
  spec:
    cluster:
      autoFailoverMaxCount: 1
      autoFailoverTimeout: 10s
    logging:
      server:
        enabled: true
        sidecar:
          image: couchbase/fluent-bit:${DOCKER_TAG}
      audit:
        enabled: true
    image: ${SERVER_IMAGE}
    security:
      adminSecret: cb-example-auth
    buckets:
      managed: true
    servers:
    - size: ${SERVER_COUNT}
      name: all_services
      services:
      - data
      - index
      - query
      - search
      - eventing
      - analytics
      volumeMounts:
        default: couchbase
    volumeClaimTemplates:
    - metadata:
        name: couchbase
      spec:
        storageClassName: standard
        resources:
          requests:
            storage: 1Gi
__CLUSTER_CONFIG_EOF__

    # Wait for deployment to complete
    echo "Waiting for CB to start up..."
    until [[ $(kubectl get pods --field-selector=status.phase=Running --selector='app=couchbase' --no-headers 2>/dev/null |wc -l) -eq $SERVER_COUNT ]]; do
      echo -n '.'
      sleep 2
    done
    echo "CB started"
  fi #CUSTOM_CB_CONFIG
fi #SKIP_CLUSTER_CREATION