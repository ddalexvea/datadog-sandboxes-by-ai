# Bug Report: Empty Path Warning in Autodiscovery Config Reader

## Summary

The Datadog Agent logs a confusing warning message `Skipping, open : no such file or directory` without specifying which path is missing. This occurs because the autodiscovery config reader attempts to read from an empty string path (`""`), which is a bug in input validation.

## Environment

* **Kubernetes Version:** v1.31.0 (minikube)
* **Datadog Agent Version:** 7.73.0
* **Helm Chart:** datadog/datadog (latest)
* **Platform:** Kubernetes on minikube (Docker driver)

## The Bug

### Location in Code

**File:** [`comp/core/autodiscovery/providers/config_reader.go`](https://github.com/DataDog/datadog-agent/blob/0d01ac5d467532a882cec5b282463cdf0315ae48/comp/core/autodiscovery/providers/config_reader.go#L205-L221)

**Lines ~215-219:**
```go
for _, path := range r.paths {
    log.Infof("Searching for configuration files at: %s", path)  // Empty path logged here
    
    entries, err := os.ReadDir(path)  // os.ReadDir("") fails
    if err != nil {
        log.Warnf("Skipping, open %s: %s", path, err)  // Confusing message with no path
        continue
    }
}
```

### Problem

1. The `r.paths` slice contains an empty string `""`
2. No validation is performed to filter out empty paths before processing
3. `os.ReadDir("")` is called, which fails
4. The warning message `"Skipping, open %s: %s"` with an empty string produces: `Skipping, open : no such file or directory`

## Reproduction Steps

### 1. Create Kubernetes Cluster

```bash
minikube start
```

### 2. Install Datadog Agent

```bash
# Add Helm repo
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Create secret
kubectl create secret generic datadog-secret \
  --from-literal api-key=<YOUR_API_KEY>

# Create values file
cat > datadog-values.yaml << 'EOF'
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "minikube"
  kubelet:
    tlsVerify: false
EOF

# Install agent
helm install datadog-agent -f datadog-values.yaml datadog/datadog
```

### 3. Wait for Agent to Start

```bash
kubectl get pods -w
```

### 4. Check Agent Logs

```bash
kubectl logs <datadog-agent-pod> -c agent 2>&1 | grep -E "(Searching for configuration files at|Skipping, open)"
```

### 5. Observe the Bug

**Output:**
```
2025-12-18 13:10:19 UTC | CORE | INFO | (comp/core/autodiscovery/providers/config_reader.go:215 in read) | Searching for configuration files at: /etc/datadog-agent/conf.d
2025-12-18 13:10:19 UTC | CORE | INFO | (comp/core/autodiscovery/providers/config_reader.go:215 in read) | Searching for configuration files at: /opt/datadog-agent/bin/agent/dist/conf.d
2025-12-18 13:10:19 UTC | CORE | WARN | (comp/core/autodiscovery/providers/config_reader.go:219 in read) | Skipping, open /opt/datadog-agent/bin/agent/dist/conf.d: no such file or directory
2025-12-18 13:10:19 UTC | CORE | INFO | (comp/core/autodiscovery/providers/config_reader.go:215 in read) | Searching for configuration files at: 
2025-12-18 13:10:19 UTC | CORE | WARN | (comp/core/autodiscovery/providers/config_reader.go:219 in read) | Skipping, open : no such file or directory
```

**Note:** The last two lines show:
- `Searching for configuration files at: ` (empty path)
- `Skipping, open : no such file or directory` (no path in error message)

## Expected Behavior

The agent should either:
1. **Skip empty paths silently** - Don't add empty strings to the paths slice
2. **Or log a descriptive message** - `Skipping: configuration path is empty`

## Actual Behavior

- Empty paths are added to `r.paths` without validation
- Agent attempts `os.ReadDir("")` which fails
- Warning message lacks the path, making debugging difficult

## Impact

- **Functional Impact:** None - the agent works correctly
- **Operational Impact:** Confusing logs that make troubleshooting harder
- **User Experience:** Users spend time investigating a non-issue

## Investigation: Source of Empty Path

### Paths Being Searched

| # | Path | Source | Status |
|---|------|--------|--------|
| 1 | `/etc/datadog-agent/conf.d` | `confd_path` config | ✅ OK |
| 2 | `/opt/datadog-agent/bin/agent/dist/conf.d` | Legacy dist path | ⚠️ Doesn't exist (expected) |
| 3 | `""` (empty) | **Unknown** | 🐛 BUG |

### Unknown Source

The empty path is added to `r.paths` somewhere in the path initialization code, but the exact source was not identified. Likely candidates:
- Hardcoded empty string in path array construction
- Uninitialized configuration variable
- Bug in `InitConfigFilesReader()` caller

## Verification Commands

### Check agent logs for the warning:
```bash
kubectl logs <agent-pod> -c agent 2>&1 | grep "Skipping, open :"
```

### Check agent configuration:
```bash
kubectl exec <agent-pod> -c agent -- agent config 2>&1
```

### Check agent version:
```bash
kubectl exec <agent-pod> -c agent -- agent version
```

## Timeline

- **December 2025:** Present in Agent 7.73.0

---

**Tested by:** Alexandre VEA  
**Date:** December 18, 2025

