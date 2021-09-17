#!/bin/bash
set -eux
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# To create a cluster run this first:
# kind create cluster

# Build our image and load it into the cluster
docker build -t cbes-launcher:v1 -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}/launcher/"
kind load docker-image cbes-launcher:v1

# Delete anything already there
kubectl delete -f "${SCRIPT_DIR}/deployment.yaml" || true
# We need RBAC privileges to access the API - this should be done separately really (or in the YAML)
kubectl create clusterrolebinding default-view --clusterrole=view --serviceaccount=default:default || true
# Now deploy what we have
kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"