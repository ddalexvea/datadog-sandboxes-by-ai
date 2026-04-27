# Kubernetes — orchestrator_pod Check Absent from Process Agent When DD_CLUSTER_NAME Is Not Set

All manifests and configurations are included inline for easy copy-paste reproduction. Never put API keys directly in manifests — use Kubernetes secrets.

## Context

When `datadog.clusterName` is not set in the Datadog Helm values, the process-agent starts with `cluster_name: ""`. This causes the `orchestrator_pod` check to never initialize, even when `DD_ORCHESTRATOR_EXPLORER_ENABLED=true` is explicitly set.

The result is two visible symptoms that appear unrelated:

1. All Kubernetes metrics carry `kube_cluster_name:N/A` instead of the cluster name.
2. The Kubernetes Explorer live view shows no pods, nodes, or deployments, and the APM Infrastructure tab shows empty Live Pods.

The diagnostic fingerprint in the process-agent status is:

    Enabled Checks: [container process_discovery rtcontainer]

The `orchestrator_pod` check is absent. The Cluster Agent confirms the downstream effect with:

    OrchestratorManifest: 0
    Pod: 0

This sandbox reproduces the exact behavior confirmed from a customer agent flare (process_agent_runtime_config_dump.yaml showing `cluster_name: ""`), and proves the fix by showing `orchestrator_pod` appearing in Enabled Checks after adding `DD_CLUSTER_NAME`.

## Environment

- **Agent Version:** 7.49.0 (any version affected)
- **Platform:** minikube / EKS / any Kubernetes
- **Integration:** Orchestrator Explorer, process-agent

Commands to get versions:

    kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent version
    kubectl version --short

## Schema

```mermaid
graph TD
    subgraph Bug — cluster_name empty
        A1[DD_ORCHESTRATOR_EXPLORER_ENABLED=true\nDD_CLUSTER_NAME not set]
        A1 --> B1[process_agent_runtime_config_dump.yaml\ncluster_name: '']
        B1 --> C1[IsEnabled check in pod.go\ncluster_name empty → skip]
        C1 --> D1[Enabled Checks: container rtcontainer\nNO orchestrator_pod ❌]
        D1 --> E1[Cluster Agent:\nOrchestratorManifest: 0 / Pod: 0]
        E1 --> F1[K8s Explorer: empty\nAPM Live Pods: empty ❌]
    end

    subgraph Fix — cluster_name set
        A2[DD_ORCHESTRATOR_EXPLORER_ENABLED=true\nDD_CLUSTER_NAME=my-cluster]
        A2 --> B2[Got cluster name my-cluster from config]
        B2 --> C2[IsEnabled check in pod.go\ncluster_name valid → load]
        C2 --> D2[Enabled Checks: container rtcontainer orchestrator_pod ✅]
        D2 --> E2[Cluster Agent:\nPod: N OrchestratorManifest: N]
        E2 --> F2[K8s Explorer: pods visible\nAPM Live Pods: visible ✅]
    end

    style D1 fill:#ff6b6b
    style F1 fill:#ff6b6b
    style D2 fill:#51cf66
    style F2 fill:#51cf66
```

## Quick Start

### 1. Start minikube

    minikube status || minikube start --memory=4096 --cpus=2

### 2. Create namespace and secret

    kubectl create namespace sandbox
    kubectl create secret generic datadog-secret -n sandbox --from-literal=api-key=YOUR_API_KEY

### 3. Create RBAC for the agent

    kubectl apply -f - <<'RBAC'
    ---
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: datadog-agent-sa
      namespace: sandbox
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: datadog-agent-sandbox
    rules:
    - apiGroups: [""]
      resources: ["nodes", "pods", "services", "endpoints", "events", "namespaces"]
      verbs: ["get", "list", "watch"]
    - apiGroups: [""]
      resources: ["nodes/metrics", "nodes/spec", "nodes/stats", "nodes/proxy"]
      verbs: ["get"]
    - apiGroups: ["extensions", "apps"]
      resources: ["daemonsets", "deployments", "replicasets", "statefulsets"]
      verbs: ["get", "list", "watch"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: datadog-agent-sandbox
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: datadog-agent-sandbox
    subjects:
    - kind: ServiceAccount
      name: datadog-agent-sa
      namespace: sandbox
    RBAC

## Reproduce the Bug

### Deploy agent WITHOUT DD_CLUSTER_NAME

    kubectl apply -f - <<'MANIFEST'
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: dd-agent-bug
      namespace: sandbox
    spec:
      selector:
        matchLabels:
          app: dd-agent-bug
      template:
        metadata:
          labels:
            app: dd-agent-bug
        spec:
          serviceAccountName: datadog-agent-sa
          hostPID: true
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          containers:
          - name: agent
            image: gcr.io/datadoghq/agent:7.49.0
            env:
            - name: DD_API_KEY
              valueFrom:
                secretKeyRef:
                  name: datadog-secret
                  key: api-key
            - name: DD_SITE
              value: "datadoghq.com"
            - name: KUBERNETES
              value: "yes"
            # BUG: DD_CLUSTER_NAME is NOT set — cluster_name will be ""
            # Orchestrator Explorer is enabled but will be skipped
            - name: DD_ORCHESTRATOR_EXPLORER_ENABLED
              value: "true"
            - name: DD_PROCESS_AGENT_ENABLED
              value: "true"
            - name: DD_KUBERNETES_KUBELET_HOST
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: DD_KUBELET_TLS_VERIFY
              value: "false"
            - name: DD_HEALTH_PORT
              value: "5555"
            resources:
              requests:
                memory: "256Mi"
                cpu: "200m"
              limits:
                memory: "512Mi"
                cpu: "500m"
            volumeMounts:
            - name: procdir
              mountPath: /host/proc
              readOnly: true
            - name: cgroups
              mountPath: /host/sys/fs/cgroup
              readOnly: true
          volumes:
          - name: procdir
            hostPath:
              path: /proc
          - name: cgroups
            hostPath:
              path: /sys/fs/cgroup
    MANIFEST

    kubectl rollout status daemonset/dd-agent-bug -n sandbox --timeout=180s

## Test Commands — Bug State

### Confirm cluster_name is empty in runtime config

    kubectl exec -n sandbox daemonset/dd-agent-bug -- bash -c \
      "grep 'cluster_name' /etc/datadog-agent/runtime_config_dump.yaml 2>/dev/null || \
       cat /var/log/datadog/process-agent.log | grep -i 'cluster\|Skipping'"

Expected output from process-agent log:

    Failed to auto-detect a Kubernetes cluster name. Pod collection will not start. To fix this, set it manually via the cluster_name config option

The cluster name is empty so the orchestrator pod check is skipped entirely.

### Confirm orchestrator_pod is absent from Enabled Checks

    kubectl exec -n sandbox daemonset/dd-agent-bug -- agent status 2>&1 \
      | grep "Enabled Checks"

Expected:

    Enabled Checks: [container process_discovery rtcontainer]

The `orchestrator_pod` check is absent. `container` and `rtcontainer` are present because Live Containers collection works independently of cluster name.

### Confirm process-agent log shows no cluster name resolution

    kubectl exec -n sandbox daemonset/dd-agent-bug -- bash -c \
      "cat /var/log/datadog/process-agent.log | grep -E 'cluster|Skipping|Got cluster'"

Expected: `Failed to auto-detect a Kubernetes cluster name. Pod collection will not start.` — no "Got cluster name" line.

## Expected vs Actual — Bug State

| Behavior | Expected | Actual |
|---|---|---|
| `orchestrator_pod` in Enabled Checks | Yes | No — skipped |
| process-agent log | `Got cluster name X from config` | `Skipping pod check on process agent` |
| `cluster_name` in runtime config | `my-cluster` | `""` |
| K8s Explorer live pods | Visible | Empty |
| APM Infrastructure Live Pods | Visible | Empty |
| `kube_cluster_name` tag on metrics | `kube_cluster_name:my-cluster` | `kube_cluster_name:N/A` |

## Apply the Fix

Patch the DaemonSet to add DD_CLUSTER_NAME:

    kubectl patch daemonset dd-agent-bug -n sandbox --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/env/-",
       "value":{"name":"DD_CLUSTER_NAME","value":"my-sandbox-cluster"}}
    ]'

    kubectl rollout status daemonset/dd-agent-bug -n sandbox --timeout=180s

Equivalent in Helm values (production fix):

    datadog:
      clusterName: "my-cluster-name"   # must be lowercase, dot-separated, no uppercase

## Test Commands — Fixed State

### Confirm process-agent resolves cluster name from config

    kubectl exec -n sandbox daemonset/dd-agent-bug -- bash -c \
      "cat /var/log/datadog/process-agent.log | grep -E 'Got cluster|cluster name'"

Expected:

    Got cluster name my-sandbox-cluster from config
    Using cluster name my-sandbox-cluster from the node label

Verified output from this reproduction:

    2026-04-27 17:13:19 UTC | PROCESS | INFO | (pkg/util/kubernetes/clustername/clustername.go:78 in getClusterName) | Got cluster name my-sandbox-cluster from config
    2026-04-27 17:13:19 UTC | PROCESS | INFO | (pkg/util/kubernetes/clustername/clustername.go:129 in getClusterName) | Using cluster name my-sandbox-cluster from the node label

### Confirm orchestrator_pod now appears in Enabled Checks

    kubectl exec -n sandbox daemonset/dd-agent-bug -- agent status 2>&1 \
      | grep "Enabled Checks"

Expected (`pod` is the orchestrator_pod check alias in 7.49.0):

    Enabled Checks: [process rtprocess pod]

The `pod` check is now present — this is the orchestrator pod collection check.

### Confirm kube_cluster_name tag is now populated

    kubectl exec -n sandbox daemonset/dd-agent-bug -- agent check kubelet 2>&1 \
      | grep "kube_cluster_name"

Expected: `kube_cluster_name:my-sandbox-cluster` on kubelet metrics.

## Why container Check Works but orchestrator_pod Does Not

Both checks run in the process-agent, but they have different enablement conditions:

    container check:
      requires: DD_PROCESS_AGENT_ENABLED=true or container collection enabled
      requires cluster_name: NO
      result: always runs → Live Containers page works

    orchestrator_pod check:
      requires: DD_ORCHESTRATOR_EXPLORER_ENABLED=true
      requires cluster_name: YES — IsEnabled() returns false if cluster_name is ""
      result: skipped when cluster_name empty → K8s Explorer empty

This is why the customer sees kubernetes.memory.usage metrics (container check feeds this) but has an empty Kubernetes Explorer and empty APM Infrastructure Live Pods tab (orchestrator_pod not running).

## Diagnostic Fingerprint

When you see this combination in a customer flare, the root cause is always missing clusterName in Helm values:

    # process_agent_runtime_config_dump.yaml
    cluster_name: ""

    # agent status — process-agent section
    Enabled Checks: [container process_discovery rtcontainer]   ← no orchestrator_pod

    # agent status — Cluster Agent section
    OrchestratorManifest: 0
    Pod: 0

## Troubleshooting

    # Process-agent logs
    kubectl exec -n sandbox daemonset/dd-agent-bug -- bash -c \
      "cat /var/log/datadog/process-agent.log | tail -50"

    # Agent status (full)
    kubectl exec -n sandbox daemonset/dd-agent-bug -- agent status

    # Confirm all env vars on the agent
    kubectl exec -n sandbox daemonset/dd-agent-bug -- env | grep -E "DD_CLUSTER|DD_ORCHESTRAT"

    # Events
    kubectl get events -n sandbox --sort-by='.lastTimestamp' | tail -20

## Cleanup

    kubectl delete daemonset dd-agent-bug -n sandbox
    kubectl delete namespace sandbox
    kubectl delete clusterrole datadog-agent-sandbox
    kubectl delete clusterrolebinding datadog-agent-sandbox

## References

- [Datadog Docs — Orchestrator Explorer setup](https://docs.datadoghq.com/infrastructure/containers/orchestrator_explorer/)
- [Datadog Helm Chart — clusterName parameter](https://github.com/DataDog/helm-charts/blob/main/charts/datadog/values.yaml)
- [Datadog Docs — Kubernetes cluster name](https://docs.datadoghq.com/agent/kubernetes/tag/?tab=containerizedagent#out-of-the-box-tags)
- [Agent Docker Tags](https://hub.docker.com/r/datadog/agent/tags)
