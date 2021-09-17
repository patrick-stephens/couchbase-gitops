#!/bin/bash
set -eux
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

docker build -t cbes-launcher:v1 -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}/launcher/"
kind load docker-image cbes-launcher:v1

kubectl delete -f "${SCRIPT_DIR}/deployment.yaml" || true
kubectl create clusterrolebinding default-view --clusterrole=view --serviceaccount=default:default || true
kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"