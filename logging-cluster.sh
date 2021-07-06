#!/bin/bash
set -eu

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
REPO_DIR=${REPO_DIR:-$SCRIPT_DIR/couchbase-operator}
CONFIG_DIR=$(mktemp -d)
CLUSTER=${CLUSTER:-logging-test}
CONFIG="${CONFIG_DIR}/multinode-cluster-conf.yaml"
USE_PVC=${USE_PVC:-yes}
USE_ES=${USE_ES:-no}
USE_CUSTOM_CONFIG=${USE_CUSTOM_CONFIG:-no}
USE_NODE_MONITOR=${USE_NODE_MONITOR:-yes}
USE_AGGREGATOR=${USE_AGGREGATOR:-yes}

CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-docker}
USE_MANUAL_AUDITING=${USE_MANUAL_AUDITING:-no}

USE_NATS=${USE_NATS:-no}
USE_PROMETHEUS=${USE_PROMETHEUS:-no}
USE_AZURITE=${USE_AZURITE:-no}

FLUENT_BIT_IMAGE=${FLUENT_BIT_IMAGE:-"fluent/fluent-bit:1.7"}
FLUENT_BIT_MOUNT_PATH=${FLUENT_BIT_MOUNT_PATH:-"/fluent-bit/etc"}

SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-no}

pushd "${REPO_DIR}"

if [[ "${SKIP_CLUSTER_CREATION}" != "yes" ]]; then
  echo "Recreating full cluster"
  docker system prune --volumes --all --force
  make && make container

  # Simple script to deal with running up a test cluster for KIND for developing logging updates for.
  cat << EOF > "${CONFIG}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
 EphemeralContainers: true
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
EOF

  kind delete clusters --all
  kind create cluster --name=${CLUSTER} --config=${CONFIG}
  echo "$(date) waiting for cluster..."
  until kubectl cluster-info;  do
      echo -n "."
      sleep 2
  done
  echo -n " done"

  # Ensure we have everything we need
  kind load docker-image couchbase/couchbase-operator:v1 --name=${CLUSTER}
  kind load docker-image couchbase/couchbase-operator-admission:v1 --name=${CLUSTER}
  # Not strictly required but improves caching performance
  docker pull couchbase/server:6.6.2
  kind load docker-image couchbase/server:6.6.2 --name=${CLUSTER}
  # It also slows down everything to allow the cluster to come up fully

  docker pull k8s.gcr.io/node-problem-detector/node-problem-detector:v0.8.6
  kind load docker-image k8s.gcr.io/node-problem-detector/node-problem-detector:v0.8.6 --name=${CLUSTER}

  rm -rf "${CONFIG_DIR}"

  # Check we can use the storage ok
  if ! kubectl get sc standard -o yaml|grep -q "volumeBindingMode: WaitForFirstConsumer"; then
      echo "Standard storage class is not lazy binding so needs manual set up"
      exit 1
  fi

  # Install CRD, DAC and operator
  kubectl create -f ${REPO_DIR}/example/crd.yaml
  ${REPO_DIR}/build/bin/cbopcfg create admission --image=couchbase/couchbase-operator-admission:v1 --log-level=debug
  ${REPO_DIR}/build/bin/cbopcfg create operator --image=couchbase/couchbase-operator:v1 --log-level=debug

  # Set up ConfigMap to use for FluentBit
  if [[ "${USE_CUSTOM_CONFIG}" == "yes" ]]; then
    CONFIGMAP_YAML=$(mktemp)
    cat << __CONFIGMAP_EOF__ >> ${CONFIGMAP_YAML}
apiVersion: v1
kind: Secret
metadata:
  name: fluent-bit-config
stringData:
  # Configuration files: server, input, filters and output
  # ======================================================
  fluent-bit.conf: |
    [SERVICE]
        flush        1
        daemon       Off
        log_level    info
        parsers_file parsers.conf

    # Add information for this container as standard keys: https://docs.fluentbit.io/manual/pipeline/filters/modify
    # This is required to simplify downstream parsing to filter the different pod logs
    [FILTER]
        Name modify
        Match *
        Add pod \${HOSTNAME}
        Add logshipper couchbase.sidecar.fluentbit

    @include output.conf
    @include input.conf

  input.conf: |
    [INPUT]
        Name tail
        Path \${COUCHBASE_LOGS}/audit.log
        Parser auditdb_log
        # Read from the start of the file when you start up
        Path_Key filename
        Tag couchbase.log.audit

    [INPUT]
        Name tail
        Path \${COUCHBASE_LOGS}/indexer.log
        Parser simple_log
        Path_Key filename
        Tag couchbase.log.indexer
    # Note this logger seems to not use a common case for level strings, i.e. info, Info and INFO are all provided.
    # We can manage with some Lua scripting here or leave to downstream fluentd, etc. to deal with.
    # https://github.com/shunwen/fluent-plugin-rename-key/issues/19#issuecomment-528027457

    [INPUT]
        Name tail
        Path \${COUCHBASE_LOGS}/memcached.log.000000.txt
        # Make sure we only grab the latest version, not any rotated ones
        Parser simple_log
        Path_Key filename
        Tag couchbase.log.memcached

    [INPUT]
        Name tail
        Path \${COUCHBASE_LOGS}/babysitter.log,\${COUCHBASE_LOGS}/couchdb.log
        Multiline On
        Parser_Firstline erlang_multiline
        Path_Key filename
        Skip_Long_Lines On
        # We want to tag with the name of the log so we can easily send named logs to different output destinations.
        # This requires a bit of regex to extract the info we want.
        Tag couchbase.log.<logname>
        Tag_Regex \${COUCHBASE_LOGS}/(?<logname>[^.]+).log$

    # For completeness, capture anything else that might appear but do not output it by default
    [INPUT]
        Name tail
        Path \${COUCHBASE_LOGS}/*.log
        Exclude_Path *audit.log,couchdb.log,babysitter.log,indexer.log
        Path_Key filename
        Skip_Long_Lines On
        # Filter out by using the .raw prefix
        Tag couchbase.raw.log.<logname>
        Tag_Regex \${COUCHBASE_LOGS}/(?<logname>[^.]+).log$

  parsers.conf: |
    [PARSER]
        Name         auditdb_log
        Format       json
        Time_Key     timestamp
        Time_Format  %Y-%m-%dT%H:%M:%S.%L

    [PARSER]
        Name simple_log
        Format regex
        Regex ^(?<time>\d+-\d+-\d+T\d+:\d+:\d+.\d+(\+|-)\d+:\d+)\s+\[(?<level>\w+)\](?<message>.*)$
        Time_Key time
        Time_Format %Y-%m-%dT%H:%M:%S.%L%z

    [PARSER]
        Name erlang_multiline
        Format regex
        Regex ^\[(?<logger>\w+):(?<level>\w+),(?<time>\d+-\d+-\d+T\d+:\d+:\d+.\d+Z).*](?<message>.*)$
        Time_Key time
        Time_Format %Y-%m-%dT%H:%M:%S.%L

  output.conf: |
    # Output all parsed logs by default
    [OUTPUT]
        name  stdout
        match couchbase.log.*
        json_date_key false

__CONFIGMAP_EOF__
  fi

  if [[ "${USE_AZURITE}" == "yes" ]]; then
    echo "Deploying Azurite"
    cat << __AZURITE_EOF__ | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: azurite
  labels:
    app: azurite
spec:
  ports:
  - port: 10000
  selector:
    app: azurite
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azurite-deployment
  labels:
    app: azurite
spec:
  replicas: 1
  selector:
    matchLabels:
      app: azurite
  template:
    metadata:
      labels:
        app: azurite
    spec:
      containers:
      - name: azurite
        image: mcr.microsoft.com/azure-storage/azurite
        ports:
        - containerPort: 10000
__AZURITE_EOF__
    if [[ "${USE_CUSTOM_CONFIG}" == "yes" ]]; then
      # Add an output to Azurite
      cat << __CONFIGMAP_EOF__ >> ${CONFIGMAP_YAML}
    [OUTPUT]
        name                  azure_blob
        match                 *
        account_name          devstoreaccount1
        shared_key            Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==
        path                  kubernetes
        container_name        logs
        auto_create_container on
        tls                   off
        emulator_mode         on
        endpoint              http://azurite:10000

__CONFIGMAP_EOF__
    fi


  fi
  if [[ "${USE_ES}" == "yes" ]]; then
    # Better options available, e.g. https://github.com/elastic/helm-charts/tree/master/elasticsearch/examples/kubernetes-kind
    echo "Deploy Elasticsearch - single node, no persistence"
    cat << __ES_EOF__ | kubectl apply -f -
kind: Service
apiVersion: v1
metadata:
  name: elasticsearch
  labels:
    app: elasticsearch
spec:
  selector:
    app: elasticsearch
  clusterIP: None
  ports:
    - port: 9200
      name: rest
    - port: 9300
      name: inter-node
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: es-cluster
spec:
  serviceName: elasticsearch
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      containers:
      - name: elasticsearch
        image: docker.elastic.co/elasticsearch/elasticsearch:7.2.0
        resources:
            limits:
              cpu: 1000m
            requests:
              cpu: 100m
        ports:
        - containerPort: 9200
          name: rest
          protocol: TCP
        - containerPort: 9300
          name: inter-node
          protocol: TCP
        env:
          - name: cluster.name
            value: k8s-logs
          - name: node.name
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: discovery.seed_hosts
            value: "es-cluster-0.elasticsearch"
          - name: cluster.initial_master_nodes
            value: "es-cluster-0"
          - name: ES_JAVA_OPTS
            value: "-Xms512m -Xmx512m"
---
apiVersion: v1
kind: Service
metadata:
  name: kibana
  labels:
    app: kibana
spec:
  ports:
  - port: 5601
  selector:
    app: kibana
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kibana
  labels:
    app: kibana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kibana
  template:
    metadata:
      labels:
        app: kibana
    spec:
      containers:
      - name: kibana
        image: docker.elastic.co/kibana/kibana:7.2.0
        resources:
          limits:
            cpu: 1000m
          requests:
            cpu: 100m
        env:
          - name: ELASTICSEARCH_URL
            value: http://elasticsearch:9200
        ports:
        - containerPort: 5601
__ES_EOF__

    if [[ "${USE_CUSTOM_CONFIG}" == "yes" ]]; then
      # Add an output to Elasticsearch
      cat << __CONFIGMAP_EOF__ >> ${CONFIGMAP_YAML}
    [OUTPUT]
        name  es
        match couchbase.log.*
        Logstash_Format On
        Include_Tag_Key On
        Tag_Key FluentBit-Key
        Host elasticsearch
        Port 9200

__CONFIGMAP_EOF__
    fi
    # To use kibana:
    # kubectl port-forward service/kibana 5601

  fi

  if [[ "${USE_CUSTOM_CONFIG}" == "yes" ]]; then
    kubectl apply -f ${CONFIGMAP_YAML}
    rm -f ${CONFIGMAP_YAML}
  fi

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

  # Now create a cluster using the specified config
  #kubectl create -f ${REPO_DIR}/docs/user/modules/ROOT/examples/kubernetes/couchbase-cluster.yaml
  CLUSTER_CONFIG_YAML=$(mktemp)
  cat << __CLUSTER_CONFIG_EOF__ >> ${CLUSTER_CONFIG_YAML}
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
  monitoring:
    prometheus:
      enabled: true
  logging:
    server:
      enabled: true
__CLUSTER_CONFIG_EOF__
    if [[ "${USE_CUSTOM_CONFIG}" == "yes" ]]; then
      echo "Using custom config so disabling operator managed config"
      cat << __CLUSTER_CONFIG_EOF__ >> ${CLUSTER_CONFIG_YAML}
      manageConfiguration: false
__CLUSTER_CONFIG_EOF__
    fi
    cat << __CLUSTER_CONFIG_EOF__ >> ${CLUSTER_CONFIG_YAML}
      sidecar:
        image: "${FLUENT_BIT_IMAGE}"
        configurationMountPath: "${FLUENT_BIT_MOUNT_PATH}"
    audit:
      enabled: true
      rotation:
        size: "1Mi"
      garbageCollection:
        sidecar:
          enabled: true
          interval: "1m"
          age: "1m"
  image: couchbase/server:6.6.2
  security:
    adminSecret: cb-example-auth
  buckets:
    managed: true
  servers:
  - size: 3
    name: all_services
    services:
    - data
    - index
    - query
    - search
    - eventing
    - analytics
__CLUSTER_CONFIG_EOF__

  if [[ "${USE_PVC}" == "yes" ]]; then
    cat << __CLUSTER_CONFIG_EOF__ >> ${CLUSTER_CONFIG_YAML}
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
  fi
  kubectl create -f ${CLUSTER_CONFIG_YAML}
  rm -f ${CLUSTER_CONFIG_YAML}

  # Wait for deployment to complete
  echo "Waiting for CB to start up..."
  until [[ $(kubectl get pods --field-selector=status.phase=Running --selector='app=couchbase' --no-headers 2>/dev/null |wc -l) -eq 3 ]]; do
    echo -n '.'
    sleep 2
  done
  echo -n " done"
fi #SKIP_CLUSTER_CREATION

# Access REST API
echo "Waiting for REST API..."
kubectl port-forward cb-example-0000 8091 &>/dev/null &
PORT_FORWARD_PID=$!

# We need to wait for the CB server to start up and respond to REST API
until curl --silent --show-error -X GET -u Administrator:password http://localhost:8091/settings/audit &>/dev/null; do
  echo -n '.'
  sleep 2
done
echo -n " done"

if [[ "${USE_MANUAL_AUDITING}" == "yes" ]]; then
  echo "Enable auditing"
  # Ensure we enable auditing (and its associated logging) to generate events
  # Enable logging of all events
  # Set log rotation to be fairly often (1024 bytes) to make sure we're generating rotated versions
  curl --silent --show-error -X POST -u Administrator:password http://localhost:8091/settings/audit \
    -d auditdEnabled=true \
    -d rotateSize=1024 \
    -d disabled= | jq
fi

echo "Audit settings:"
curl --silent --show-error -X GET -u Administrator:password http://localhost:8091/settings/audit | jq

kill -9 $PORT_FORWARD_PID &>/dev/null


echo "Run test case"
kubectl apply -f example/tools/pillowfight-data-loader.yaml

# Now start up the extra components
if [[ "${USE_NODE_MONITOR}" == "yes" ]]; then
  echo "Start monitor"
  MONITOR_CONFIG_YAML=$(mktemp)
  cat << __MONITOR_EOF__ > ${MONITOR_CONFIG_YAML}
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
kind: ConfigMap
metadata:
  name: node-problem-detector-config
  namespace: kube-system
apiVersion: v1
data:
  kernel-monitor.json: |
    {
        "plugin": "kmsg",
        "logPath": "/dev/kmsg",
        "lookback": "5m",
        "bufferSize": 10,
        "source": "kernel-monitor",
        "conditions": [
            {
                "type": "KernelDeadlock",
                "reason": "KernelHasNoDeadlock",
                "message": "kernel has no deadlock"
            },
            {
                "type": "ReadonlyFilesystem",
                "reason": "FilesystemIsNotReadOnly",
                "message": "Filesystem is not read-only"
            }
        ],
        "rules": [
            {
                "type": "temporary",
                "reason": "OOMKilling",
                "pattern": "Killed process \\\d+ (.+) total-vm:\\\d+kB, anon-rss:\\\d+kB, file-rss:\\\d+kB.*"
            },
            {
                "type": "temporary",
                "reason": "TaskHung",
                "pattern": "task \\\S+:\\\w+ blocked for more than \\\w+ seconds\\\."
            },
            {
                "type": "temporary",
                "reason": "UnregisterNetDevice",
                "pattern": "unregister_netdevice: waiting for \\\w+ to become free. Usage count = \\\d+"
            },
            {
                "type": "temporary",
                "reason": "KernelOops",
                "pattern": "BUG: unable to handle kernel NULL pointer dereference at .*"
            },
            {
                "type": "temporary",
                "reason": "KernelOops",
                "pattern": "divide error: 0000 \\\[#\\\d+\\\] SMP"
            },
            {
    			"type": "temporary",
    			"reason": "MemoryReadError",
    			"pattern": "CE memory read error .*"
            },
            {
                "type": "permanent",
                "condition": "KernelDeadlock",
                "reason": "AUFSUmountHung",
                "pattern": "task umount\\\.aufs:\\\w+ blocked for more than \\\w+ seconds\\\."
            },
            {
                "type": "permanent",
                "condition": "KernelDeadlock",
                "reason": "DockerHung",
                "pattern": "task docker:\\\w+ blocked for more than \\\w+ seconds\\\."
            },
            {
                "type": "permanent",
                "condition": "ReadonlyFilesystem",
                "reason": "FilesystemIsReadOnly",
                "pattern": "Remounting filesystem read-only"
            }
        ]
    }
  docker-monitor.json: |
    {
        "plugin": "journald",
        "pluginConfig": {
            "source": "dockerd"
        },
        "logPath": "/run/log/journal",
        "lookback": "5m",
        "bufferSize": 10,
        "source": "docker-monitor",
        "conditions": [],
        "rules": [
            {
                "type": "temporary",
                "reason": "CorruptDockerImage",
                "pattern": "Error trying v2 registry: failed to register layer: rename /var/lib/docker/image/(.+) /var/lib/docker/image/(.+): directory not empty.*"
            }
        ]
    }
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
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/os
                    operator: In
                    values:
                      - linux
      containers:
      - name: node-problem-detector
        command:
        - /node-problem-detector
        - --logtostderr
        - --config.system-log-monitor=/config/kernel-monitor.json,/config/docker-monitor.json
        - --prometheus-port=2020
        ports:
        - containerPort: 2020
        image: k8s.gcr.io/node-problem-detector/node-problem-detector:v0.8.7
        resources:
          limits:
            cpu: 10m
            memory: 80Mi
          requests:
            cpu: 10m
            memory: 80Mi
        imagePullPolicy: Always
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
        - name: kmsg
          mountPath: /dev/kmsg
          readOnly: true
        # Make sure node problem detector is in the same timezone
        # with the host.
        - name: localtime
          mountPath: /etc/localtime
          readOnly: true
        - name: config
          mountPath: /config
          readOnly: true
      volumes:
      - name: log
        # Config `log` to your system log directory
        hostPath:
          path: /var/log/
      - name: kmsg
        hostPath:
          path: /dev/kmsg
      - name: localtime
        hostPath:
          path: /etc/localtime
      - name: config
        configMap:
          name: node-problem-detector-config
          items:
          - key: kernel-monitor.json
            path: kernel-monitor.json
          - key: docker-monitor.json
            path: docker-monitor.json
__MONITOR_EOF__
  kubectl apply -f "${MONITOR_CONFIG_YAML}"
  rm -f "${MONITOR_CONFIG_YAML}"
fi

if [[ "${USE_PROMETHEUS}" == "yes" ]]; then
  echo "Adding Prometheus node exporter for Kubernetes metrics"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm install prometheus prometheus-community/prometheus
  # kubectl port-forward $(kubectl get pods --namespace default -l "app=prometheus,component=server" -o jsonpath="{.items[0].metadata.name}") 9091
fi

if [[ "${USE_NATS}" == "yes" ]]; then
  echo "Starting NATS as an endpoint"
  curl -sSL https://nats-io.github.io/k8s/setup.sh | sh -s -- --without-tls --without-auth
fi

if [[ "${USE_AGGREGATOR}" == "yes" ]]; then
  echo "Start aggregator"
  helm repo add grafana https://grafana.github.io/helm-charts
  helm upgrade --install loki grafana/loki-stack \
  --set fluent-bit.enabled=false,promtail.enabled=true,grafana.enabled=true,prometheus.enabled=true,prometheus.alertmanager.persistentVolume.enabled=false,prometheus.server.persistentVolume.enabled=false
  #kubectl get secret loki-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
  #kubectl port-forward service/loki-grafana 3000:80

  # Use https://github.com/kvaps/kubectl-node-shell to get a shell on the node
  # nodes=$(kubectl get nodes | sed '1d' | awk '{print $1}') && for node in $nodes; do;  kubectl describe node | sed -n '/Conditions/,/Ready/p' ; done
fi

popd