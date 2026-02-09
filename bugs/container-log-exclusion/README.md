# Bug Report: `container_exclude_logs` Ignored When Using Namespace-Level Filtering

## Summary
When using `container_exclude` with `container_include` for namespace-level filtering, the `container_exclude_logs` configuration is completely ignored in Datadog Agent versions 7.69.0 and later. This is a regression from version 7.68.3 where the exclusion worked correctly.

## Environment
- **Kubernetes Version:** v1.31.0 (minikube)
- **Datadog Agent Version (Broken):** 7.71.2
- **Datadog Agent Version (Working):** 7.68.3
- **Helm Chart:** datadog/datadog (latest)
- **Platform:** Kubernetes on minikube (Docker driver)

## Configuration

### Helm Values (`values.yaml`)
```yaml
datadog:
  apiKey: <API_KEY>
  
  kubelet:
    tlsVerify: false  # For minikube compatibility
  
  logs:
    enabled: true
    containerCollectAll: true
  
  # Exclude all namespaces by default
  containerExclude: "kube_namespace:.*"
  
  # Include specific namespace
  containerInclude: "kube_namespace:test-logs"
  
  # Exclude logs from specific container
  containerExcludeLogs: "name:^main-app$"
```

### Runtime Config (as seen in agent)
```yaml
container_exclude:
  - kube_namespace:.*

container_include:
  - kube_namespace:test-logs

container_exclude_logs:
  - name:^main-app$
```

## Test Environment

### Test Pods
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: test-logs
---
apiVersion: v1
kind: Pod
metadata:
  name: test-app
  namespace: test-logs
spec:
  containers:
  - name: main-app
    image: busybox
    command: ["/bin/sh", "-c"]
    args: ["while true; do echo 'Main app log message'; sleep 2; done"]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-app-2
  namespace: test-logs
spec:
  containers:
  - name: application
    image: busybox
    command: ["/bin/sh", "-c"]
    args: ["while true; do echo 'Application log'; sleep 3; done"]
```

## Expected Behavior
With the above configuration:
- **Logs from `test-logs/test-app/main-app`** should be **EXCLUDED** (due to `containerExcludeLogs: name:^main-app$`)
- **Logs from `test-logs/test-app-2/application`** should be **COLLECTED** (included by namespace, not excluded by name)

## Actual Behavior

### Agent 7.68.3 (✅ WORKING)
```
Integrations
============

test-logs/test-app-2/application
--------------------------------
  - Type: file
    Status: OK
    Bytes Read: 3141

# main-app is NOT listed = correctly excluded ✅
```

### Agent 7.71.2 (❌ BROKEN)
```
Integrations
============

test-logs/test-app-2/application
--------------------------------
  - Type: file
    Status: OK
    Bytes Read: 2540

test-logs/test-app/main-app
---------------------------
  - Type: file
    Status: OK
    Bytes Read: 3900   # ❌ Should be excluded but is being tailed!
```

## Reproduction Steps

1. Create a Kubernetes cluster (or use minikube)

2. Create test namespace and pods:
```bash
kubectl apply -f test-log-exclusion.yaml
```

3. Install Datadog Agent 7.71.2 with the configuration above:
```bash
helm install datadog-test datadog/datadog \
  -f values.yaml \
  --namespace datadog \
  --create-namespace
```

4. Wait for agent to be ready and check status:
```bash
kubectl exec -n datadog <agent-pod> -- agent status | grep -A10 "main-app"
```

5. **Observe:** `main-app` container logs are being collected despite being in `container_exclude_logs`

6. Downgrade to Agent 7.68.3:
```yaml
agents:
  image:
    tag: 7.68.3
```

7. Upgrade helm release:
```bash
helm upgrade datadog-test datadog/datadog -f values.yaml --namespace datadog
```

8. **Observe:** `main-app` container logs are now correctly excluded

## Verification Commands

### Check agent version:
```bash
kubectl exec -n datadog <agent-pod> -- agent version
```

### Check runtime configuration:
```bash
kubectl exec -n datadog <agent-pod> -- agent config | grep -A5 container_exclude_logs
```

### Check which containers are being tailed:
```bash
kubectl exec -n datadog <agent-pod> -- agent status | grep -A15 "Integrations"
```

### Check container discovery:
```bash
kubectl exec -n datadog <agent-pod> -- agent workload-list | grep <namespace>
```

## Additional Notes
- The configuration loads correctly (visible in `agent config`)
- Containers are properly discovered (visible in `agent workload-list`)
- The filtering logic appears to work for metrics (`container_exclude_metrics`)
- Only log collection filtering is broken when namespace-level includes/excludes are used

## Regression Timeline
- **7.68.3 and earlier:** ✅ Working correctly
- **7.71.2+ (current):** ❌ Broken

## Related Configuration Files
The issue has been reproduced with both:
- Direct `datadog.yaml` configuration
- Helm chart values
- Environment variables (`DD_CONTAINER_EXCLUDE_LOGS`)

All methods exhibit the same broken behavior in affected versions.

---

**Tested by:** Alexandre VEA (Datadog Support)  
**Date:** November 3, 2025  
**Ticket Reference:** Customer case with istio-proxy log exclusion issue

