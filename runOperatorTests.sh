#!/bin/bash
set -eux
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
OPERATOR_REPO_DIR=$(find $SCRIPT_DIR/../ -type d -name "couchbase-operator" -print0)
LOGSHIPPER_REPO_DIR=$(find $SCRIPT_DIR/../ -type d -name "couchbase-operator-logging" -print0)

DOCKER_TAG=${DOCKER_TAG:-v1}
SERVER_IMAGE=${SERVER_IMAGE:-couchbase/server:6.6.1}

RECREATE_CLUSTER=${RECREATE_CLUSTER:-no}

pushd "${OPERATOR_REPO_DIR}"
make && make container
popd

pushd "${LOGSHIPPER_REPO_DIR}"
make container container-rhel
popd

if [[ "${RECREATE_CLUSTER}" == "yes" ]]; then
    kind delete clusters --all
    kind create cluster
fi
kind load docker-image "couchbase/couchbase-operator:${DOCKER_TAG}"
kind load docker-image "couchbase/couchbase-operator-admission:${DOCKER_TAG}"
kind load docker-image "couchbase/operator-logging:${DOCKER_TAG}"
kind load docker-image "couchbase/operator-logging-rhel:${DOCKER_TAG}"

# Not strictly required but improves caching performance
docker pull "${SERVER_IMAGE}"
kind load docker-image "${SERVER_IMAGE}"

pushd "${OPERATOR_REPO_DIR}"
go test github.com/couchbase/couchbase-operator/test/e2e -run TestOperator -v --race -timeout 24h -parallel 1 -args -color --logging-image "couchbase/operator-logging:${DOCKER_TAG}" "$@"
popd