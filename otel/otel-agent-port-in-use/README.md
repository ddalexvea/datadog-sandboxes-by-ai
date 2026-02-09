# OTEL Port Conflict Sandbox

## 📋 Summary

**Issue:** OTEL Agent container failing with port conflict errors when using `hostNetwork: true`  
**Helm Chart Version:** 3.123.3  
**Agent Version:** 7.67.0  

---

## 🔴 Problem Description

When deploying Datadog with `otelCollector.enabled: true` and `useHostNetwork: true`, the otel-agent container may fail with:

```
OTELCOL | ERROR | Error running the collector pipeline: 
failed to build extensions: failed to create extension "ddflare/dd-autoconfigured": 
listen tcp 127.0.0.1:7777: bind: address already in use

OTELCOL | ERROR | Error running the collector pipeline: 
failed to create SDK: binding address localhost:8888 for Prometheus exporter: 
listen tcp 127.0.0.1:8888: bind: address already in use
```

The agent status shows:

```
OTel Agent
==========
  Status: Not running or unreachable on https://localhost:7777.
  Error: Get "https://localhost:7777": http: server gave HTTP response to HTTPS client
```

---

## 🔧 Configuration That Triggers This Issue

The issue occurs when **both** of these settings are enabled:

```yaml
agents:
  useHostNetwork: true  # <-- Shares host network namespace

datadog:
  otelCollector:
    enabled: true       # <-- Enables otel-agent container
```

**Why this combination causes issues:**
- `useHostNetwork: true` makes the pod use the host's network
- `otelCollector.enabled: true` starts the otel-agent container which binds to port 7777
- If anything else on the host already uses port 7777, the otel-agent fails

---

## 🔍 Root Cause Analysis

### The Issue

When `useHostNetwork: true` is enabled:
- All containers in the Datadog pod share the **host's network namespace**
- Port 7777 on `127.0.0.1` refers to the **host's loopback interface**
- If **any other process on the host** is already using port 7777, the otel-agent's `ddflare` extension cannot bind to it

### Understanding the Error Messages

1. **"listen tcp 127.0.0.1:7777: bind: address already in use"**
   - The otel-agent tried to bind to port 7777 but another process already occupies it

2. **"http: server gave HTTP response to HTTPS client"**
   - The core agent tries to connect to `https://localhost:7777`
   - Something IS listening on 7777 but it responds with HTTP (not HTTPS)
   - This confirms another process (not the otel-agent) is using the port

### Ports Used by OTEL Agent

| Port | Purpose | Protocol |
|------|---------|----------|
| 7777 | ddflare extension | HTTPS |
| 8888 | Prometheus metrics exporter | HTTP |
| 4317 | OTLP gRPC receiver | gRPC |
| 4318 | OTLP HTTP receiver | HTTP |

---

## 🧪 Reproduction Steps

### Environment Setup

```bash
# 1. Start fresh minikube
minikube delete --all
minikube start --driver=docker --memory=4096 --cpus=2

# 2. Create namespace and secret
kubectl create namespace datadog
kubectl create secret generic datadog-secret \
  --from-literal api-key=YOUR_API_KEY -n datadog

# 3. Add Datadog helm repo
helm repo add datadog https://helm.datadoghq.com
helm repo update
```

### Create Values File (Minimal Configuration)

```yaml
# /tmp/repro-values.yaml
# Minimal configuration to reproduce the issue

agents:
  useHostNetwork: true  # Required to trigger the issue

datadog:
  apiKeyExistingSecret: datadog-secret
  otelCollector:
    enabled: true       # Required to trigger the issue
```

### Step 1: Deploy Without Port Conflict (Baseline)

```bash
# Deploy Datadog
helm install datadog datadog/datadog --version 3.123.3 \
  -f /tmp/repro-values.yaml -n datadog

# Wait for pods
sleep 45

# Verify otel-agent is working
kubectl exec -n datadog $(kubectl get pods -n datadog -l app=datadog -o name | head -1) \
  -c agent -- agent status | grep -A10 "OTel Agent"
```

**Expected Output (Working):**
```
OTel Agent
==========
  Status: Running
  Agent Version: 7.67.0 
  Collector Version: v0.125.0 
```

### Step 2: Create Port Blocker to Simulate Conflict

```bash
# Uninstall Datadog first
helm uninstall datadog -n datadog

# Create a pod that blocks port 7777 (simulating another process on the host)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: port-7777-blocker
  namespace: default
spec:
  hostNetwork: true
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["/bin/sh", "-c"]
    args:
    - |
      echo 'server { listen 7777; location / { return 200 "port 7777 blocked"; } }' > /etc/nginx/conf.d/default.conf
      nginx -g 'daemon off;'
EOF

# Wait for blocker to be ready
kubectl wait --for=condition=Ready pod/port-7777-blocker --timeout=60s

# Verify port 7777 is blocked
minikube ssh "ss -tlnp | grep 7777"
# Expected: LISTEN 0 511 0.0.0.0:7777 0.0.0.0:*
```

### Step 3: Deploy Datadog and Observe the Conflict

```bash
# Deploy Datadog with OTEL enabled
helm install datadog datadog/datadog --version 3.123.3 \
  -f /tmp/repro-values.yaml -n datadog

# Wait for pods
sleep 30

# Check otel-agent logs for error
kubectl logs -n datadog $(kubectl get pods -n datadog -l app=datadog -o name | head -1) \
  -c otel-agent | grep -i "error\|7777"
```

**Expected Error Output:**
```
Error running the collector pipeline: failed to build extensions: 
failed to create extension "ddflare/dd-autoconfigured": 
listen tcp 127.0.0.1:7777: bind: address already in use
```

### Step 4: Verify Agent Status Shows the Issue

```bash
kubectl exec -n datadog $(kubectl get pods -n datadog -l app=datadog -o name | head -1) \
  -c agent -- agent status | grep -A10 "OTel Agent"
```

**Expected Status Output:**
```
OTel Agent
==========
  Status: Not running or unreachable on https://localhost:7777.
  Error: Get "https://localhost:7777": http: server gave HTTP response to HTTPS client
```

### Step 5: Verify the Blocker is Responding

```bash
minikube ssh "curl -s http://127.0.0.1:7777"
# Expected: port 7777 blocked
```

---

## ✅ Resolution Steps

### Remove the Port Blocker and Verify Fix

```bash
# 1. Delete the port blocker
kubectl delete pod port-7777-blocker

# 2. Restart the Datadog agent pod
kubectl delete pod -n datadog -l app=datadog

# 3. Wait for pod to restart
sleep 30

# 4. Verify otel-agent is now working
kubectl exec -n datadog $(kubectl get pods -n datadog -l app=datadog -o name | head -1) \
  -c agent -- agent status | grep -A10 "OTel Agent"
```

**Expected Working Status:**
```
OTel Agent
==========
  Status: Running
  Agent Version: 7.67.0 
  Collector Version: v0.125.0 

  Receiver
  ==========================
    Spans Accepted: 0
    Metric Points Accepted: 103
```

---

## 📝 Troubleshooting Steps

### Identify What's Using Port 7777

Run the following commands **on the affected Kubernetes nodes** (not in containers):

```bash
# Check what process is using port 7777
# -t = TCP only | -l = listening | -n = numeric ports | -p = show process
# Shows: process name + PID in format: users:(("process_name",pid=XXXX,fd=X))
sudo ss -tlnp | grep 7777

# Alternative using netstat (older systems)
# -t = TCP only | -l = listening | -n = numeric ports | -p = show process
# Shows: PID/process_name in last column
sudo netstat -tlnp | grep 7777

# Alternative using lsof
# -i :7777 = show processes using port 7777
# Shows: full details including COMMAND, PID, USER
sudo lsof -i :7777
```

**Example output (ss):**
```
LISTEN 0 511 0.0.0.0:7777 0.0.0.0:* users:(("nginx",pid=25637,fd=6))
```
This shows: process `nginx` with PID `25637` is using port 7777.

### Common Culprits

1. **Other monitoring tools** that use these ports
2. **Previous Datadog deployments** that weren't fully cleaned up
3. **Custom applications** running on the nodes
4. **Node management agents** or system services
5. **Other OTEL collectors** running on the host

---

## 🛠️ Workarounds

### Option 1: Identify and Stop the Conflicting Process (Recommended)

Identify what's using port 7777 and either:
- Stop it
- Reconfigure it to use a different port

### Option 2: Disable hostNetwork (if not required)

If `hostNetwork` is not strictly required for your use case:

```yaml
agents:
  useHostNetwork: false  # Each container gets its own network namespace
```

This gives each container its own network namespace, eliminating host port conflicts.

### Option 3: Configure Custom Ports for OTEL Extensions

If needed, the otel-agent can potentially be configured to use different ports for its internal extensions via environment variables or custom OTEL configuration.

---

## 📊 Test Results Summary

| Scenario | Port 7777 | OTel Agent Status |
|----------|-----------|-------------------|
| No blocker | Free | ✅ Running |
| With port blocker | Occupied by nginx (HTTP) | ❌ Failed to bind |
| Blocker removed | Free | ✅ Running |

---

## 🔗 Related Documentation

- [Datadog OTEL Collector on Kubernetes](https://docs.datadoghq.com/opentelemetry/setup/ddot_collector/install/kubernetes_daemonset/?tab=helm)
- [Datadog Helm Chart Values](https://github.com/DataDog/helm-charts/tree/main/charts/datadog)
- [Kubernetes hostNetwork](https://kubernetes.io/docs/concepts/services-networking/host-networking/)
- [OpenTelemetry Collector Extensions](https://opentelemetry.io/docs/collector/configuration/#extensions)

---

## 🧹 Cleanup

```bash
# Remove all test resources
kubectl delete pod port-7777-blocker --ignore-not-found
helm uninstall datadog -n datadog
kubectl delete namespace datadog
minikube delete
```
