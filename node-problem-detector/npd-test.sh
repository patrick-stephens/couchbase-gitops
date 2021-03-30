#!/bin/bash
set -eux

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-yes}
REBUILD_ALL=${REBUILD_ALL:-no}
SERVER_COUNT=${SERVER_COUNT:-3}
CLUSTER_NAME=${CLUSTER:-logshipper-test}

NPD_IMAGE=${NPD_IMAGE:-couchbase-npd:v1}

SERVER_COUNT=${SERVER_COUNT} SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION} CLUSTER_NAME=${CLUSTER_NAME} REBUILD_ALL=${REBUILD_ALL} /bin/bash "${SCRIPT_DIR}/../createCluster.sh"

docker build -f Dockerfile -t "${NPD_IMAGE}" .
kind load docker-image "${NPD_IMAGE}" --name="${CLUSTER_NAME}" 

# Now start up the node problem detector (or re-apply if already present)
echo "Start monitor"
cat << __MONITOR_EOF__ | kubectl apply -f -
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
 name: role-monitor-account
rules:
- apiGroups: [""]
  resources: ["nodes", "nodes/status", "events"]
  verbs: ["get", "patch", "create", "update", "delete"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
 name: role-monitor-account-binding
subjects:
- kind: ServiceAccount
  name: default
  namespace: kube-system
roleRef:
 kind: ClusterRole
 name: role-monitor-account
 apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-problem-detector
  namespace: kube-system
  labels:
    app: node-problem-detector
spec:
  selector:
    matchLabels:
      app: node-problem-detector
  template:
    metadata:
      labels:
        app: node-problem-detector
    spec:
      hostPID: true
      hostNetwork: true
      containers:
      - name: node-problem-detect
        image: ${NPD_IMAGE}
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: log
          mountPath: /var/log
          readOnly: true
        # Make sure node problem detector is in the same timezone
        # with the host.
        - name: localtime 
          mountPath: /etc/localtime
          readOnly: true
        - name: hostproc
          mountPath: /host/proc
          readOnly: true
      volumes:
      - name: log
        # Config log to your system log directory
        hostPath:
          path: /var/log/
      - name: localtime
        hostPath:
          path: /etc/localtime
      - name: hostproc
        hostPath:
          path: /proc
__MONITOR_EOF__

# Always restart the DS to ensure we pick up the latest image
kubectl rollout restart ds -n kube-system node-problem-detector