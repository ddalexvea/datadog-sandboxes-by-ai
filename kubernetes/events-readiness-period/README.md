# Kubernetes Events + Datadog Integration Lab

Complete lab setup for monitoring Kubernetes Events with Datadog Agent, featuring unbundled events collection and readiness probe event generation.

## 🎯 Overview

This lab demonstrates:

* **Datadog Agent** installation via Helm with Kubernetes Events collection
* **Unbundled Events** configuration for granular event tracking
* **Test Application** with configurable readiness probe to generate events
* **Event timestamp verification** with different `periodSeconds` values
* **Known Issue Reproduction** - Same timestamp bug on Agent v7.57.2

## 📋 Prerequisites

* Minikube installed and running
* kubectl configured
* Helm 3.x installed
* Datadog API key

## 🚀 Quick Start

### 1. Start Minikube

```bash
minikube delete  # Clean start (optional)
minikube start --driver=docker --cpus=4 --memory=4000
```

### 2. Add Datadog Helm Repository

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update
```

### 3. Create Datadog Secret

```bash
kubectl create secret generic datadog-secret \
  --from-literal api-key=YOUR_DATADOG_API_KEY
```

### 4. Create Datadog Values File

Create `datadog-values.yaml`:

```yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "minikube"
  kubelet:
    tlsVerify: false
  kubernetesEvents:
    unbundleEvents: true
```

### 5. Install Datadog Agent

```bash
helm install datadog-agent -f datadog-values.yaml datadog/datadog
```

### 6. Verify Datadog Agent is Running

```bash
# Check all Datadog pods
kubectl get pods -l app=datadog-agent
kubectl get pods -l app=datadog-agent-cluster-agent

# Expected output:
# NAME                                          READY   STATUS    RESTARTS   AGE
# datadog-agent-xxxxx                           2/2     Running   0          1m
# datadog-agent-cluster-agent-xxxxx-xxxxx       1/1     Running   0          1m
```

### 7. Deploy Test Application with Readiness Probe

Create `test-app-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-app
  labels:
    app: test-app
spec:
  containers:
  - name: app
    image: busybox:latest
    command: ["/bin/sh", "-c"]
    args:
      - |
        # Create the ready file initially so the pod becomes ready
        touch /tmp/ready
        echo "Pod started. Ready file created."
        # Keep the container running
        while true; do sleep 3600; done
    readinessProbe:
      exec:
        command:
        - cat
        - /tmp/ready
      initialDelaySeconds: 5
      periodSeconds: 20
      failureThreshold: 1
      successThreshold: 1
```

Apply the pod:

```bash
kubectl apply -f test-app-pod.yaml
```

### 8. Verify Test Application is Running

```bash
kubectl get pod test-app

# Expected output:
# NAME       READY   STATUS    RESTARTS   AGE
# test-app   1/1     Running   0          30s
```

## 🔄 Generating Kubernetes Events

### Make Pod NOT Ready (Generate Unhealthy Events)

```bash
kubectl exec test-app -- rm /tmp/ready
```

This will trigger `Unhealthy` warning events every 20 seconds (based on `periodSeconds`).

### Make Pod Ready Again

```bash
kubectl exec test-app -- touch /tmp/ready
```

### Watch Events in Real-Time

```bash
kubectl get events --field-selector involvedObject.name=test-app -w
```

### View Event Details with Timestamps

```bash
kubectl get events --field-selector involvedObject.name=test-app,reason=Unhealthy -o yaml
```

Sample output:

```yaml
apiVersion: v1
items:
- apiVersion: v1
  count: 6
  eventTime: null
  firstTimestamp: "2025-12-03T09:24:28Z"
  involvedObject:
    apiVersion: v1
    fieldPath: spec.containers{app}
    kind: Pod
    name: test-app
    namespace: default
  kind: Event
  lastTimestamp: "2025-12-03T09:25:30Z"
  message: "Readiness probe failed: cat: can't open '/tmp/ready': No such file or directory"
  reason: Unhealthy
  type: Warning
```

## 📊 Viewing Events in Datadog

### Events Explorer

Navigate to: **https://app.datadoghq.com/event/explorer**

Filter by:
- `source:kubernetes`
- `cluster_name:minikube`
- `reason:Unhealthy`

### With Unbundled Events

When `kubernetesEvents.unbundleEvents: true` is enabled:
- Each Kubernetes event occurrence appears as a **separate** Datadog event
- Events have **distinct timestamps** matching the actual occurrence time
- Provides granular visibility into event frequency and timing

### Without Unbundled Events (Default)

When `unbundleEvents` is `false` or not set:
- Similar events are **bundled together**
- You see aggregated events with `count` information
- Less granular but reduces event volume

## ⚙️ Configuration Details

### Key Helm Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `datadog.kubernetesEvents.unbundleEvents` | Send each K8s event as individual Datadog event | `false` |
| `datadog.clusterName` | Cluster name tag for all data | Required |
| `datadog.kubelet.tlsVerify` | Verify kubelet TLS certificates | `true` |
| `datadog.site` | Datadog intake site | `datadoghq.com` |

### Readiness Probe Parameters

| Parameter | Description | Our Value |
|-----------|-------------|-----------|
| `periodSeconds` | How often to perform the probe | `20` |
| `initialDelaySeconds` | Delay before first probe | `5` |
| `failureThreshold` | Failures before marking unhealthy | `1` |
| `successThreshold` | Successes before marking healthy | `1` |
| `timeoutSeconds` | Probe timeout | `1` (default) |

### Event Collection Architecture

```
┌─────────────────┐     ┌─────────────────────┐     ┌─────────────┐
│   Kubernetes    │────▶│  Datadog Cluster    │────▶│   Datadog   │
│   API Server    │     │       Agent         │     │   Intake    │
│   (Events)      │     │  (Event Collector)  │     │             │
└─────────────────┘     └─────────────────────┘     └─────────────┘
```

**Important:** Kubernetes Events are collected by the **Cluster Agent**, not the node agent.

## 📈 Expected Event Timeline

With `periodSeconds: 20` and pod in unhealthy state:

| Time (seconds) | Event |
|----------------|-------|
| 0 | Ready file removed |
| ~20 | First Unhealthy event |
| ~40 | Second Unhealthy event |
| ~60 | Third Unhealthy event |
| ... | Continues every 20s |

## 🐛 Known Issue: Same Timestamp on Unbundled Events (Agent v7.57.2)

### Issue Description

When using **Datadog Agent v7.57.2** with `kubernetesEvents.unbundleEvents: true`, multiple unbundled events appear in Datadog with the **exact same timestamp**, even though they should have distinct timestamps based on `periodSeconds`.

### Reproduction Steps

1. **Install Datadog Agent v7.57.2** with unbundled events enabled:

```yaml
# datadog-values.yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "minikube"
  kubelet:
    tlsVerify: false
  kubernetesEvents:
    unbundleEvents: true

agents:
  image:
    tag: 7.57.2

clusterAgent:
  image:
    tag: 7.57.2
```

```bash
helm install datadog-agent -f datadog-values.yaml datadog/datadog
```

2. **Deploy test application** with readiness probe (`periodSeconds: 20`):

```bash
kubectl apply -f test-app-pod.yaml
```

3. **Make the pod unhealthy** to generate events:

```bash
kubectl exec test-app -- rm /tmp/ready
```

4. **Wait 2-3 minutes** for multiple events to be generated

5. **Check Datadog Events Explorer** - Filter by:
   - `source:kubernetes`
   - `reason:Unhealthy`
   - `pod_name:test-app`

### Expected vs Actual Behavior

| Expected (Correct) | Actual (v7.57.2 Bug) |
|--------------------|----------------------|
| Event 1: 10:49:32 | Event 1: **10:49:52** |
| Event 2: 10:49:52 | Event 2: **10:49:52** |
| Event 3: 10:50:12 | Event 3: **10:49:52** |

With `periodSeconds: 20`, each event should have a timestamp ~20 seconds apart. Instead, all unbundled events show the **same timestamp**.

---

## 🔧 Troubleshooting

### Issue: Events Not Appearing in Datadog

**Checklist:**
1. ✅ Verify Cluster Agent is running: `kubectl get pods -l app=datadog-agent-cluster-agent`
2. ✅ Check Cluster Agent logs: `kubectl logs -l app=datadog-agent-cluster-agent`
3. ✅ Verify API key is correct
4. ✅ Check `datadog.site` matches your Datadog account region

### Issue: Events Have Same Timestamp

**Possible Causes:**
1. `unbundleEvents` not enabled
2. **Datadog Agent v7.57.2 bug** - See [Known Issue](#-known-issue-same-timestamp-on-unbundled-events-agent-v7572) above
3. Cluster Agent event batching behavior

**Solution:**
1. Enable unbundled events:
```yaml
datadog:
  kubernetesEvents:
    unbundleEvents: true
```

2. **Upgrade Agent to v7.60+ or latest**:
```yaml
agents:
  image:
    tag: 7.68.2
clusterAgent:
  image:
    tag: 7.68.2
```

### Issue: Kubelet Connection Errors

**Error:**
```
Unable to connect to kubelet
```

**Solution:**
```yaml
datadog:
  kubelet:
    tlsVerify: false
```

### Debug Commands

```bash
# Check Datadog Agent status
kubectl exec -it $(kubectl get pods -l app=datadog-agent -o jsonpath='{.items[0].metadata.name}') -- agent status

# Check Cluster Agent status
kubectl exec -it $(kubectl get pods -l app=datadog-agent-cluster-agent -o jsonpath='{.items[0].metadata.name}') -- datadog-cluster-agent status

# View Cluster Agent logs for events
kubectl logs -l app=datadog-agent-cluster-agent | grep -i event

# List all events in namespace
kubectl get events --sort-by='.lastTimestamp'

# Describe test pod events
kubectl describe pod test-app | grep -A 20 "Events:"
```

## 🧹 Cleanup

```bash
# Delete test application
kubectl delete pod test-app

# Uninstall Datadog Agent
helm uninstall datadog-agent

# Delete secret
kubectl delete secret datadog-secret

# Stop minikube
minikube stop

# OR delete cluster entirely
minikube delete
```

## 🔗 References

* [Datadog Kubernetes Events Documentation](https://docs.datadoghq.com/containers/kubernetes/events/)
* [Datadog Helm Chart Values](https://github.com/DataDog/helm-charts/blob/main/charts/datadog/values.yaml)
* [Kubernetes Probe Configuration](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
* [Datadog Events Explorer](https://docs.datadoghq.com/events/explorer/)

## 📝 Key Takeaways

✅ **Enable `unbundleEvents: true`** for granular event tracking  
✅ **Cluster Agent collects events**, not the node agent  
✅ **`periodSeconds` controls** how often probes run and events are generated  
✅ **Use `kubectl get events -w`** to watch events in real-time  
✅ **Upgrade Datadog Agent** to latest version for best event handling  
✅ **Filter events by `reason`** (Unhealthy, Killing, etc.) for targeted monitoring

---

**Lab Created:** December 3, 2025  
**Cluster:** minikube  
**Datadog Site:** datadoghq.com  
**Datadog Agent Version:** Latest (7.68.x recommended)

