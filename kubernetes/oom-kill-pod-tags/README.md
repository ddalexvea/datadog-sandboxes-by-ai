# Datadog OOM Kill Integration Setup on Minikube

This guide walks through installing Datadog on a minikube cluster with OOM kill detection enabled and properly configured with Kubernetes pod tags.

## Prerequisites

- minikube cluster running
- helm 3.x installed
- kubectl configured

## Step 1: Add Datadog Helm Repository

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update
```

## Step 2: Create Datadog API Key Secret

```bash
kubectl create secret generic datadog-secret --from-literal api-key=YOUR_API_KEY
```

Replace `YOUR_API_KEY` with your actual Datadog API key.

## Step 3: Create Datadog Values File

Create a file named `datadog-values.yaml` with the following configuration:

```yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "minikube"
  kubelet:
    tlsVerify: false
  systemProbe:
    enableOOMKill: true
  env:
    - name: DD_CHECKS_TAG_CARDINALITY
      value: "orchestrator"
```

### Configuration Breakdown:

- **`site`**: Your Datadog site (e.g., `datadoghq.com`, `datadoghq.eu`)
- **`apiKeyExistingSecret`**: Reference to the Kubernetes secret containing the API key
- **`clusterName`**: Identifier for your cluster in Datadog
- **`kubelet.tlsVerify: false`**: Required for minikube to allow agent to connect to kubelet
- **`systemProbe.enableOOMKill`**: Enables OOM kill detection using eBPF
- **`DD_CHECKS_TAG_CARDINALITY: orchestrator`**: Enables high-cardinality tags including `pod_name`

## Step 4: Install Datadog Agent

```bash
helm install datadog-agent -f datadog-values.yaml datadog/datadog
```

## Step 5: Verify Installation

Check that all Datadog pods are running:

```bash
kubectl get pods -l app.kubernetes.io/instance=datadog-agent
```

Expected output:
```
NAME                                          READY   STATUS    RESTARTS   AGE
datadog-agent-9jf7p                            3/3     Running   0          2m
datadog-agent-cluster-agent-7d5bc59856-9hhwz   1/1     Running   0          2m
```

The agent pod should have **3 containers**:
- `agent`
- `trace-agent`
- `system-probe` (for OOM kill detection)

## Step 6: Verify OOM Kill Check is Active

```bash
kubectl exec -it <datadog-agent-pod-name> -- agent status | grep -A 15 "oom_kill"
```

Expected output:
```
oom_kill
--------
  Instance ID: oom_kill [OK]
  Configuration Source: file:/etc/datadog-agent/conf.d/oom_kill.d/conf.yaml.default
  Total Runs: X
  Metric Samples: Last Run: X, Total: X
  Events: Last Run: X, Total: X
```

## Step 7: Verify Tag Cardinality Configuration

```bash
kubectl exec -it <datadog-agent-pod-name> -- agent config | grep -i "checks_tag_cardinality"
```

Expected output:
```
checks_tag_cardinality: orchestrator
```

## Step 8: Verify Orchestrator Check is Working

```bash
kubectl exec -it <datadog-agent-pod-name> -- agent status | grep -A 10 "orchestrator_pod"
```

Expected output should show `[OK]` status:
```
orchestrator_pod
----------------
  Instance ID: orchestrator_pod:888ebc42a3817b00 [OK]
  ...
  Last Successful Execution Date : <timestamp>
```

## Step 9: Test OOM Kill Detection

Create a test pod that will trigger OOM kills:

```yaml
# oom-test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: oom-test
  labels:
    app: oom-test
spec:
  containers:
  - name: memory-eater
    image: busybox
    command: ["sh", "-c"]
    args:
    - |
      echo "Starting memory consumption test..."
      echo "Allocated memory limit: 50Mi"
      # Allocate more memory than the limit to trigger OOM
      tail /dev/zero
    resources:
      limits:
        memory: "50Mi"
      requests:
        memory: "50Mi"
  restartPolicy: Always
```

Apply the test pod:

```bash
kubectl apply -f oom-test-pod.yaml
```

## Step 10: Monitor OOM Events

Watch the pod getting OOMKilled:

```bash
kubectl get pod oom-test -w
```

Check OOM events captured by Datadog:

```bash
kubectl exec -it <datadog-agent-pod-name> -- agent status | grep -A 15 "oom_kill"
```

You should see the event count increasing:
```
Events: Last Run: 1, Total: X
```

## Step 11: View Events in Datadog

OOM kill events will be visible in the Datadog Event Explorer:
- URL: https://app.datadoghq.com/event/explorer
- Search for: `source:oom_kill`

Events should include tags such as:
- `pod_name:oom-test`
- `kube_namespace:default`
- `container_name:memory-eater`
- `kube_cluster_name:minikube`

## Step 12: Clean Up Test Resources

```bash
kubectl delete pod oom-test
rm oom-test-pod.yaml
```

## Updating Datadog Configuration

If you need to update the Datadog configuration later:

```bash
helm upgrade datadog-agent -f datadog-values.yaml datadog/datadog
```

## Troubleshooting

### Issue: Orchestrator check failing with "impossible to reach Kubelet"

**Solution**: Ensure `kubelet.tlsVerify: false` is set in your values file. This is required for minikube.

### Issue: OOM events don't have pod tags

**Solution**: Set `DD_CHECKS_TAG_CARDINALITY: orchestrator` to enable high-cardinality tags including `pod_name`.

### Issue: System-probe container not present

**Solution**: Ensure `systemProbe.enableOOMKill: true` is set under the `datadog:` section in your values file (not as a separate top-level key).

## Key Configuration Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `datadog.kubelet.tlsVerify` | `false` | Required for minikube to allow kubelet access |
| `datadog.systemProbe.enableOOMKill` | `true` | Enables eBPF-based OOM kill detection |
| `DD_CHECKS_TAG_CARDINALITY` | `orchestrator` | Enables pod-level tags on metrics and events |
| `datadog.apiKeyExistingSecret` | `datadog-secret` | References the Kubernetes secret with API key |
| `datadog.clusterName` | `minikube` | Identifies the cluster in Datadog UI |

## Final Configuration File

```yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "minikube"
  kubelet:
    tlsVerify: false
  systemProbe:
    enableOOMKill: true
  env:
    - name: DD_CHECKS_TAG_CARDINALITY
      value: "orchestrator"
```

## References

- [Datadog Kubernetes Tagging Documentation](https://docs.datadoghq.com/containers/kubernetes/tag/?tab=helm)
- [Datadog OOM Kill Integration](https://docs.datadoghq.com/integrations/oom_kill/)
- [Datadog Helm Chart Documentation](https://github.com/DataDog/helm-charts)

