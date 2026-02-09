# Kubernetes Orchestrator Explorer - Custom Tags Not Appearing on Workloads

## Overview

**Issue:** Custom tags set via pod annotations (`ad.datadoghq.com/tags`) do not appear on workload resources (Deployments, ReplicaSets, DaemonSets) in Datadog's Orchestrator Explorer.

**Root Cause:** Pod annotations are for Datadog Autodiscovery (metrics/logs/traces tagging), NOT for Kubernetes resource labels. Orchestrator Explorer displays actual Kubernetes metadata, which requires labels.

**Related Ticket:** [Zendesk #2490385](https://datadog.zendesk.com/agent/tickets/2490385)

---

## Problem Statement

Customers using ArgoCD (or similar Helm charts) often configure tags like this:

```yaml
podLabels:
  tags.datadoghq.com/service: myapp
  tags.datadoghq.com/env: prod
  tags.datadoghq.com/version: "1.0"
podAnnotations:
  ad.datadoghq.com/tags: '{"team":"platform"}'
```

**Result:**
- ✅ `service`, `env`, `version` appear on ReplicaSets in Orchestrator Explorer
- ❌ `team` does NOT appear on ReplicaSets in Orchestrator Explorer

**Why:** Kubernetes automatically copies pod **labels** to ReplicaSets, but NOT **annotations**.

---

## Reproduction

### Prerequisites

- Minikube or any Kubernetes cluster
- kubectl

### Step 1: Deploy "Broken" Configuration

This mimics the customer's setup where `team` is only in annotations:

```bash
kubectl apply -f test-deployment-before.yaml
```

Verify the issue:

```bash
# Check ReplicaSet labels
kubectl get replicaset -l app=test-app -o jsonpath='{.items[0].metadata.labels}' | jq '.'
```

**Expected Result:** ReplicaSet has `service`, `env`, `version` but NO `team` tag.

### Step 2: Apply Fix

Patch the deployment to add `team` as a pod label:

```bash
kubectl patch deployment test-app-annotations \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/metadata/labels/tags.datadoghq.com~1team", "value": "devx"}]'
```

Wait for rollout:

```bash
kubectl rollout status deployment/test-app-annotations
```

Verify the fix:

```bash
# Check new ReplicaSet labels
kubectl get replicaset -l app=test-app --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.labels}' | jq '.'
```

**Expected Result:** ReplicaSet now has `team` tag!

---

## Solution

### For ArgoCD Helm Values

Update your `values.yaml` to include custom tags as **pod labels**:

```yaml
notifications:
  podLabels:
    tags.datadoghq.com/service: argocd-notifications-controller
    tags.datadoghq.com/env: ${dd_env}
    tags.datadoghq.com/version: ${version}
    tags.datadoghq.com/team: devx  # ← Add custom tags here!
  podAnnotations:
    ad.datadoghq.com/tags: '{"team":"devx"}'  # Keep for metrics tagging
```

Apply to all ArgoCD components where you need the tag.

### For Generic Kubernetes Deployments

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    metadata:
      labels:
        # Standard k8s labels
        app: myapp
        # Unified service tags
        tags.datadoghq.com/service: myapp
        tags.datadoghq.com/env: prod
        tags.datadoghq.com/version: "1.0"
        # Custom tags for Orchestrator Explorer
        tags.datadoghq.com/team: platform  # ✅ This will appear in UI
      annotations:
        # Keep for metrics/logs/traces tagging
        ad.datadoghq.com/tags: '{"team":"platform"}'
```

---

## Key Concepts

### Pod Annotations vs Labels

| Feature | Pod Labels | Pod Annotations |
|---------|-----------|------------------|
| **Purpose** | Kubernetes metadata & selection | Arbitrary metadata (not for selection) |
| **Copied to ReplicaSet?** | ✅ Yes (automatically by Kubernetes) | ❌ No |
| **Visible in Orchestrator Explorer?** | ✅ Yes | ❌ No |
| **Used by Datadog Autodiscovery?** | Yes | Yes |

### `ad.datadoghq.com/tags` Annotation

- **Purpose:** Tags metrics, logs, and traces collected from the container
- **Scope:** Datadog telemetry only
- **Does NOT affect:** Kubernetes resource metadata in Orchestrator Explorer

### `kubernetesResourcesLabelsAsTags`

**Note:** The Datadog Agent config `kubernetesResourcesLabelsAsTags` extracts labels from Kubernetes resources for tagging **metrics**, but this is separate from what Orchestrator Explorer displays. Orchestrator Explorer shows the actual Kubernetes metadata (labels/annotations) from the Kubernetes API.

---

## Verification in Datadog UI

1. **Orchestrator Explorer:** Navigate to Infrastructure > Kubernetes > ReplicaSets
2. **Search:** Filter by your deployment name
3. **Click on ReplicaSet:** Check the "Labels" section in the side panel
4. **Verify:** You should see `tags.datadoghq.com/team: devx`

**Timeline:** Tags should appear within 5-10 minutes after the rollout completes.

---

## Related Documentation

- [Unified Service Tagging - Kubernetes](https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/?tab=kubernetes#containerized-environment)
- [Autodiscovery Annotations](https://docs.datadoghq.com/agent/kubernetes/integrations/?tab=kubernetes#configuration)
- [Kubernetes Labels and Selectors](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/)
- [Kubernetes Annotations](https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/)

---

## Files

- `test-deployment-before.yaml` - Reproduces the issue (annotation only)
- `test-deployment-after.yaml` - Fixed version (label + annotation)
- `verify-labels.sh` - Helper script to check labels

---

**Sandbox Created By:** Alexandre VEA  
**Date:** 2026-02-09  
**Ticket:** #2490385