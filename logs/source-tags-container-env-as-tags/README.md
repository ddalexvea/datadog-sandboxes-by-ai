# DD_CONTAINER_ENV_AS_TAGS - Source Tag Behavior

## Context

When using `DD_CONTAINER_ENV_AS_TAGS` to map a container environment variable to the `source` tag, the tag value **overrides** the auto-detected source from the image name.

**Use case**: Users who cannot use pod annotations (e.g., dynamic container names set by the runtime) can use `DD_CONTAINER_ENV_AS_TAGS` to control the log source tag via an environment variable.

## Environment

- **Agent Version:** 7.x (latest)
- **Platform:** minikube / Kubernetes
- **Integration:** Logs

## Quick Start

### 1. Start minikube

```bash
minikube delete --all
minikube start --memory=4096 --cpus=2
```

### 2. Deploy test application

```bash
kubectl apply -f - <<'MANIFEST'
---
apiVersion: v1
kind: Namespace
metadata:
  name: sandbox
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: sandbox
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: myapp
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            while true; do
              echo "Processing task..."
              sleep 5
            done
        env:
        - name: APPLICATION_NAME
          value: "from_application_name_env"
MANIFEST
```

### 3. Wait for ready

```bash
kubectl wait --for=condition=ready pod -l app=myapp -n sandbox --timeout=300s
```

### 4. Deploy Datadog Agent

Create `values.yaml` for **Case 1 - WITH DD_CONTAINER_ENV_AS_TAGS**:

```yaml
datadog:
  apiKeyExistingSecret: "datadog-secret"
  site: "datadoghq.com"
  clusterName: "sandbox"
  kubelet:
    tlsVerify: false
  logs:
    enabled: true
    containerCollectAll: true
  env:
    - name: DD_CONTAINER_ENV_AS_TAGS
      value: '{"APPLICATION_NAME":"source"}'

clusterAgent:
  enabled: true
```

Or for **Case 2 - WITHOUT DD_CONTAINER_ENV_AS_TAGS**:

```yaml
datadog:
  apiKeyExistingSecret: "datadog-secret"
  site: "datadoghq.com"
  clusterName: "sandbox"
  kubelet:
    tlsVerify: false
  logs:
    enabled: true
    containerCollectAll: true

clusterAgent:
  enabled: true
```

Install the agent:

```bash
kubectl create namespace datadog
kubectl create secret generic datadog-secret -n datadog --from-literal=api-key=YOUR_API_KEY
helm repo add datadog https://helm.datadoghq.com && helm repo update
helm upgrade --install datadog-agent datadog/datadog -n datadog -f values.yaml
```

## Test Commands

### Verify DD_CONTAINER_ENV_AS_TAGS is set

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- env | grep DD_CONTAINER_ENV
```

### Check Logs Agent source/service

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status | grep -A15 "sandbox/myapp"
```

### Check Tagger for source tag

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent tagger-list | grep "source:"
```

## Expected vs Actual

### Case 1: WITH DD_CONTAINER_ENV_AS_TAGS

**Logs Agent Status:**

```bash
$ kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status | grep -A10 "sandbox/myapp"

  sandbox/myapp-76d8fc56b5-s2bpf/myapp
  ------------------------------------
    - Type: file
      Path: /var/log/pods/sandbox_myapp-76d8fc56b5-s2bpf_.../myapp/*.log
      Service: busybox
      Source: busybox
      Status: OK
```

**Tagger:**

```bash
$ kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent tagger-list | grep "source:"

=Tags: [container_name:myapp ... short_image:busybox source:from_application_name_env]
```

**Result in Datadog UI:**

| Tag | Value |
|-----|-------|
| `source` | `from_application_name_env` |
| `service` | `busybox` |

The `source` tag from `DD_CONTAINER_ENV_AS_TAGS` overrides the auto-detected source from the image name.

### Case 2: WITHOUT DD_CONTAINER_ENV_AS_TAGS

**Logs Agent Status:**

```bash
$ kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status | grep -A10 "sandbox/myapp"

  sandbox/myapp-76d8fc56b5-s2bpf/myapp
  ------------------------------------
    - Type: file
      Path: /var/log/pods/sandbox_myapp-76d8fc56b5-s2bpf_.../myapp/*.log
      Service: busybox
      Source: busybox
      Status: OK
```

**Tagger:**

```bash
$ kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent tagger-list | grep "container_name:myapp"

=Tags: [container_name:myapp ... short_image:busybox]
```

No `source:` tag in tagger output.

**Result in Datadog UI:**

| Tag | Value |
|-----|-------|
| `source` | `busybox` |
| `service` | `busybox` |

Without `DD_CONTAINER_ENV_AS_TAGS`, both `source` and `service` are auto-detected from the container image name (`short_image`).

## Troubleshooting

```bash
# Pod logs
kubectl logs -n sandbox -l app=myapp --tail=100
kubectl logs -n datadog -l app=datadog-agent -c agent --tail=100

# Describe pod
kubectl describe pod -n sandbox -l app=myapp
kubectl describe pod -n datadog -l app=datadog-agent

# Get events
kubectl get events -n sandbox --sort-by='.lastTimestamp'

# Check resources
kubectl get pods -n sandbox -o wide
kubectl get pods -n datadog -o wide
```

## Cleanup

```bash
kubectl delete namespace sandbox
helm uninstall datadog-agent -n datadog
kubectl delete namespace datadog
```

## References

- [DD_CONTAINER_ENV_AS_TAGS Documentation](https://docs.datadoghq.com/containers/docker/tag/?tab=containerizedagent#extract-environment-variables-as-tags)
- [Kubernetes Log Collection](https://docs.datadoghq.com/containers/kubernetes/log/?tab=operator)
- [Log Source Auto-Detection](https://docs.datadoghq.com/logs/log_collection/?tab=docker#activate-log-integrations)
- [Agent Docker Tags](https://hub.docker.com/r/datadog/agent/tags)
re
