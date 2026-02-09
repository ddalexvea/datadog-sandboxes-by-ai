Here's the complete SNMP Trap Sandbox Setup Guide in markdown format:

```markdown
# SNMP Trap Sandbox Setup Guide

Complete step-by-step guide to set up a 3-node Kubernetes cluster with two Datadog agents receiving SNMP traps.

## Prerequisites

- Docker Desktop running
- `kubectl` installed
- `minikube` installed
- Valid Datadog API key

## Step 1: Start Minikube with 3 Nodes


# Start Docker Desktop
open -a Docker

# Wait for Docker to start, then create 3-node minikube cluster
minikube start --nodes 3 --driver=docker --memory=4096 --cpus=2
```

## Step 2: Verify Cluster Setup

```bash
# Check all nodes are ready
kubectl get nodes

# Expected output:
# NAME           STATUS   ROLES           AGE   VERSION
# minikube       Ready    control-plane   1m    v1.31.0
# minikube-m02   Ready    <none>          1m    v1.31.0
# minikube-m03   Ready    <none>          1m    v1.31.0
```

## Step 3: Create Datadog Secret

Replace `YOUR_API_KEY` with your actual Datadog API key:

```bash
# Base64 encode your API key
echo -n "YOUR_API_KEY" | base64

# Create the secret
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: datadog-secret
  namespace: default
type: Opaque
data:
  api-key: <BASE64_ENCODED_API_KEY>
EOF
```

## Step 4: Create RBAC Resources

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: datadog-agent
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: datadog-agent
rules:
- apiGroups: [""]
  resources: ["services", "events", "endpoints", "pods", "nodes", "componentstatuses"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "daemonsets", "statefulsets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: datadog-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: datadog-agent
subjects:
- kind: ServiceAccount
  name: datadog-agent
  namespace: default
EOF
```

## Step 5: Create Datadog Agent Configurations

Create separate configurations for each agent with unique tags and namespaces:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: datadog-agent-config-1
  namespace: default
data:
  datadog.yaml: |
    api_key: "YOUR_API_KEY"
    site: "datadoghq.com"  # Use "datadoghq.eu" for EU accounts
    cluster_name: "minikube-sandbox"
    logs_enabled: false
    apm_config:
      enabled: false
    process_config:
      enabled: false
    container_image_enabled: false
    container_lifecycle_enabled: false
    kubelet_tls_verify: false
    orchestrator_explorer:
      enabled: false
    cluster_checks:
      enabled: false
    network_devices:
      namespace: "agent-1"
      snmp_traps:
        enabled: true
        port: 162
        community_strings:
          - "public"
          - "private"
        bind_host: "0.0.0.0"
    tags:
      - "env:sandbox"
      - "team:monitoring"
      - "snmp_trap_receiver:true"
      - "agent_instance:datadog-agent-1"
      - "node:minikube"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: datadog-agent-config-2
  namespace: default
data:
  datadog.yaml: |
    api_key: "YOUR_API_KEY"
    site: "datadoghq.com"  # Use "datadoghq.eu" for EU accounts
    cluster_name: "minikube-sandbox"
    logs_enabled: false
    apm_config:
      enabled: false
    process_config:
      enabled: false
    container_image_enabled: false
    container_lifecycle_enabled: false
    kubelet_tls_verify: false
    orchestrator_explorer:
      enabled: false
    cluster_checks:
      enabled: false
    network_devices:
      namespace: "agent-2"
      snmp_traps:
        enabled: true
        port: 162
        community_strings:
          - "public"
          - "private"
        bind_host: "0.0.0.0"
    tags:
      - "env:sandbox"
      - "team:monitoring"
      - "snmp_trap_receiver:true"
      - "agent_instance:datadog-agent-2"
      - "node:minikube-m02"
EOF
```

## Step 6: Deploy First Datadog Agent

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: datadog-agent-1
  namespace: default
  labels:
    app: datadog-agent-1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: datadog-agent-1
  template:
    metadata:
      labels:
        app: datadog-agent-1
    spec:
      serviceAccountName: datadog-agent
      nodeSelector:
        kubernetes.io/hostname: minikube
      containers:
      - image: gcr.io/datadoghq/agent:7
        imagePullPolicy: Always
        name: datadog-agent
        ports:
        - containerPort: 8125
          name: dogstatsdport
          protocol: UDP
        - containerPort: 162
          name: snmp-trap
          protocol: UDP
        env:
        - name: DD_API_KEY
          valueFrom:
            secretKeyRef:
              name: datadog-secret
              key: api-key
        - name: DD_SITE
          value: "datadoghq.com"
        - name: DD_COLLECT_KUBERNETES_EVENTS
          value: "true"
        - name: DD_LEADER_ELECTION
          value: "false"
        - name: DD_APM_ENABLED
          value: "false"
        - name: DD_LOGS_ENABLED
          value: "false"
        - name: DD_PROCESS_AGENT_ENABLED
          value: "false"
        - name: DD_SNMP_TRAPS_ENABLED
          value: "true"
        - name: DD_SNMP_TRAPS_PORT
          value: "162"
        - name: DD_HOSTNAME
          value: "datadog-agent-1"
        - name: DD_CLUSTER_NAME
          value: "minikube-sandbox"
        - name: DD_ORCHESTRATOR_EXPLORER_ENABLED
          value: "false"
        - name: DD_CLUSTER_CHECKS_ENABLED
          value: "false"
        - name: DD_NETWORK_DEVICES_ENABLED
          value: "true"
        - name: KUBERNETES_CLUSTER_DOMAIN
          value: cluster.local
        - name: DD_KUBERNETES_KUBELET_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        volumeMounts:
        - name: config
          mountPath: /etc/datadog-agent/datadog.yaml
          subPath: datadog.yaml
        - name: dockersocketdir
          mountPath: /host/var/run
          mountPropagation: None
          readOnly: true
        - name: procdir
          mountPath: /host/proc
          mountPropagation: None
          readOnly: true
        - name: cgroups
          mountPath: /host/sys/fs/cgroup
          mountPropagation: None
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: datadog-agent-config-1
      - name: dockersocketdir
        hostPath:
          path: /var/run
      - name: procdir
        hostPath:
          path: /proc
      - name: cgroups
        hostPath:
          path: /sys/fs/cgroup
      tolerations:
      - operator: Exists
EOF
```

## Step 7: Deploy Second Datadog Agent

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: datadog-agent-2
  namespace: default
  labels:
    app: datadog-agent-2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: datadog-agent-2
  template:
    metadata:
      labels:
        app: datadog-agent-2
    spec:
      serviceAccountName: datadog-agent
      nodeSelector:
        kubernetes.io/hostname: minikube-m02
      containers:
      - image: gcr.io/datadoghq/agent:7
        imagePullPolicy: Always
        name: datadog-agent
        ports:
        - containerPort: 8125
          name: dogstatsdport
          protocol: UDP
        - containerPort: 162
          name: snmp-trap
          protocol: UDP
        env:
        - name: DD_API_KEY
          valueFrom:
            secretKeyRef:
              name: datadog-secret
              key: api-key
        - name: DD_SITE
          value: "datadoghq.com"
        - name: DD_COLLECT_KUBERNETES_EVENTS
          value: "false"
        - name: DD_LEADER_ELECTION
          value: "false"
        - name: DD_APM_ENABLED
          value: "false"
        - name: DD_LOGS_ENABLED
          value: "false"
        - name: DD_PROCESS_AGENT_ENABLED
          value: "false"
        - name: DD_SNMP_TRAPS_ENABLED
          value: "true"
        - name: DD_SNMP_TRAPS_PORT
          value: "162"
        - name: DD_HOSTNAME
          value: "datadog-agent-2"
        - name: DD_CLUSTER_NAME
          value: "minikube-sandbox"
        - name: DD_ORCHESTRATOR_EXPLORER_ENABLED
          value: "false"
        - name: DD_CLUSTER_CHECKS_ENABLED
          value: "false"
        - name: DD_NETWORK_DEVICES_ENABLED
          value: "true"
        - name: KUBERNETES_CLUSTER_DOMAIN
          value: cluster.local
        - name: DD_KUBERNETES_KUBELET_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        volumeMounts:
        - name: config
          mountPath: /etc/datadog-agent/datadog.yaml
          subPath: datadog.yaml
        - name: dockersocketdir
          mountPath: /host/var/run
          mountPropagation: None
          readOnly: true
        - name: procdir
          mountPath: /host/proc
          mountPropagation: None
          readOnly: true
        - name: cgroups
          mountPath: /host/sys/fs/cgroup
          mountPropagation: None
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: datadog-agent-config-2
      - name: dockersocketdir
        hostPath:
          path: /var/run
      - name: procdir
        hostPath:
          path: /proc
      - name: cgroups
        hostPath:
          path: /sys/fs/cgroup
      tolerations:
      - operator: Exists
EOF
```

## Step 8: Get Pod IPs and Deploy SNMP Trap Sender

First, get the current pod IPs:

```bash
kubectl get pods -o wide
```

Note the IP addresses of both datadog-agent pods, then deploy the SNMP trap sender (replace the IPs with actual ones):

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: snmp-trap-sender
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: snmp-trap-sender
  template:
    metadata:
      labels:
        app: snmp-trap-sender
    spec:
      nodeSelector:
        kubernetes.io/hostname: minikube-m03
      containers:
      - name: snmp-trap-sender
        image: alpine:latest
        command: ["/bin/sh"]
        args:
        - -c
        - |
          apk add --no-cache net-snmp-tools
          echo "Starting SNMP trap sender..."
          while true; do
            echo "Sending SNMP trap to datadog-agent-1 (REPLACE_WITH_AGENT1_IP)..."
            snmptrap -v2c -c public REPLACE_WITH_AGENT1_IP:162 '' 1.3.6.1.6.3.1.1.5.2 1.3.6.1.2.1.1.3.0 i 123456 1.3.6.1.2.1.1.1.0 s "SNMP Trap to Agent-1 namespace"
            sleep 2
            echo "Sending SNMP trap to datadog-agent-2 (REPLACE_WITH_AGENT2_IP)..."
            snmptrap -v2c -c public REPLACE_WITH_AGENT2_IP:162 '' 1.3.6.1.6.3.1.1.5.2 1.3.6.1.2.1.1.3.0 i 123456 1.3.6.1.2.1.1.1.0 s "SNMP Trap to Agent-2 namespace"
            echo "Waiting 30 seconds before next trap batch..."
            sleep 30
          done
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
          limits:
            memory: "64Mi"
            cpu: "100m"
EOF
```

## Step 9: Verify the Setup

```bash
# Check all pods are running
kubectl get pods -o wide

# Check SNMP trap sender logs
kubectl logs deployment/snmp-trap-sender --tail=10

# Check Datadog agent status (look for SNMP Traps section)
kubectl exec deployment/datadog-agent-1 -- agent status | grep -A 5 "SNMP Traps"
kubectl exec deployment/datadog-agent-2 -- agent status | grep -A 5 "SNMP Traps"

# Verify agent tags
kubectl exec deployment/datadog-agent-1 -- agent status | grep "agent_instance"
kubectl exec deployment/datadog-agent-2 -- agent status | grep "agent_instance"
```

## Step 10: View SNMP Traps in Datadog

1. Go to Datadog Log Explorer
2. Search for: `source:snmp-traps`
3. Filter by agent:
   - `agent_instance:datadog-agent-1` for traps from first agent
   - `agent_instance:datadog-agent-2` for traps from second agent
4. Use facets to see the different namespaces: `agent-1` and `agent-2`

## Key Configuration Points

1. **SNMP traps must be configured under `network_devices:` section**
2. **Each agent has unique namespace and tags for differentiation**
3. **Direct pod IP targeting works better than Kubernetes service routing for UDP**
4. **API key site must match your Datadog account region**
5. **Network device monitoring must be enabled (`DD_NETWORK_DEVICES_ENABLED=true`)**

## Troubleshooting

### If SNMP traps are not appearing:

1. **Check API key site**: Ensure you're using the correct site (`datadoghq.com` vs `datadoghq.eu`)
2. **Verify configuration structure**: SNMP traps must be under `network_devices:` section
3. **Check pod IPs**: Update SNMP trap sender if pod IPs changed after restarts
4. **Test connectivity**: 
   ```bash
   kubectl exec deployment/snmp-trap-sender -- ping POD_IP
   kubectl exec deployment/snmp-trap-sender -- nc -u -v POD_IP 162
   ```

## Cleanup

To remove the entire setup:

```bash
kubectl delete deployment datadog-agent-1 datadog-agent-2 snmp-trap-sender
kubectl delete configmap datadog-agent-config-1 datadog-agent-config-2
kubectl delete secret datadog-secret
kubectl delete clusterrolebinding datadog-agent
kubectl delete clusterrole datadog-agent
kubectl delete serviceaccount datadog-agent
minikube delete
```

This setup provides a complete SNMP trap testing environment with two differentiated Datadog agents receiving traps from a sender on a third node!
```
