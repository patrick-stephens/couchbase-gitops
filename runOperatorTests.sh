#!/bin/bash
set -eux
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
OPERATOR_REPO_DIR=$(find $SCRIPT_DIR/../ -type d -wholename '*couchbase/couchbase-operator' -print0)
LOGSHIPPER_REPO_DIR=$(find $SCRIPT_DIR/../ -type d -wholename "*couchbase/couchbase-fluent-bit" -print0)

DOCKER_TAG=${DOCKER_TAG:-v1}
SERVER_IMAGE=${SERVER_IMAGE:-couchbase/server:7.0.0}

RECREATE_CLUSTER=${RECREATE_CLUSTER:-no}

pushd "${OPERATOR_REPO_DIR}"
    make && make binaries container certification-container
popd

pushd "${LOGSHIPPER_REPO_DIR}"
    make container
popd

if [[ "${RECREATE_CLUSTER}" == "yes" ]]; then
    kind delete clusters --all
    kind create cluster
fi
kind load docker-image "couchbase/couchbase-operator:${DOCKER_TAG}"
kind load docker-image "couchbase/couchbase-operator-admission:${DOCKER_TAG}"
kind load docker-image "couchbase/fluent-bit:${DOCKER_TAG}"
kind load docker-image "couchbase/couchbase-operator-certification:${DOCKER_TAG}"

# Not strictly required but improves caching performance
docker pull "${SERVER_IMAGE}"
kind load docker-image "${SERVER_IMAGE}"

pushd "${OPERATOR_REPO_DIR}"
    # Remove old logs
    rm -rf artifacts/
    rm -rf test/e2e/logs/*
    rm -f couchbase-operator-certification*.bz2
    rm -f test/e2e/results*.xml
    # Run tests
    ./build/bin/cao certify --image "couchbase/couchbase-operator-certification:${DOCKER_TAG}" --clean --parallel=1 -- -operator-image "couchbase/couchbase-operator:${DOCKER_TAG}" -admission-image "couchbase/couchbase-operator-admission:${DOCKER_TAG}" --logging-image "couchbase/fluent-bit:${DOCKER_TAG}" "$@"
    # Extract logs for failing
    tar -xf couchbase-operator-certification*.bz2

popd
