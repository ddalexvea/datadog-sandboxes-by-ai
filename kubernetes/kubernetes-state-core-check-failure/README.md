# kubernetes_state_core Check - ControllerRevisions Permission Error

## Issue Summary

The `kubernetes_state_core` check fails with:

```
Error: resource controllerrevisions does not exist. Available resources: ...
```

**Impact:** Complete loss of Kubernetes state metrics (0 metrics collected)

## Root Cause

Custom Helm values or GitOps configuration adds `controllerrevisions` to the collectors list, but the ClusterRole is missing RBAC permissions.

This typically happens when:
- Using custom Helm values with `kubeStateMetricsCore.conf`
- ArgoCD applies custom configuration from Git
- Manual ConfigMap edits (rare)

## Environment

- **Kubernetes:** EKS, GKE, AKS, or any cluster
- **Datadog Operator:** 2.12.0+ (Helm chart)
- **Agent Version:** 7.68.2+
- **Deployment:** Datadog Operator

## Quick Diagnosis

### 1. Check if you have this issue

```bash
kubectl exec -n datadog $(kubectl get pods -n datadog \
  -l app.kubernetes.io/component=cluster-agent -o name | head -1) \
  -- agent status | grep -A 20 kubernetes_state_core
```

Look for:
```
[ERROR]
Error: resource controllerrevisions does not exist
Metric Samples: Last Run: 0, Total: 0
```

### 2. Confirm controllerrevisions is in your config

```bash
kubectl get configmap datadog-kube-state-metrics-core-config -n datadog \
  -o jsonpath='{.data.kubernetes_state_core\.yaml\.default}' | \
  grep controllerrevisions
```

If this shows `controllerrevisions`, continue to fix.

### 3. Check ClusterRole permission

```bash
kubectl auth can-i list controllerrevisions \
  --as=system:serviceaccount:datadog:datadog-cluster-agent -A
```

If this shows `no`, you're missing the permission.

## Solution Options

### Option 1: Delete ConfigMap (Recommended)

Let the Operator regenerate with correct defaults:

```bash
kubectl delete configmap datadog-kube-state-metrics-core-config -n datadog
kubectl rollout restart deployment/datadog-cluster-agent -n datadog
```

**Wait 60 seconds**, then verify:

```bash
kubectl exec -n datadog $(kubectl get pods -n datadog \
  -l app.kubernetes.io/component=cluster-agent -o name | head -1) \
  -- agent status | grep -A 15 kubernetes_state_core
```

Expected: `[OK]`, `Metric Samples: 600+`

⚠️ **If using ArgoCD:** Check if your GitOps config will re-apply the custom configuration.

### Option 2: Add ClusterRole Permission

If you need controllerrevisions monitoring:

```bash
kubectl apply -f clusterrole-fix.yaml
kubectl rollout restart deployment/datadog-cluster-agent -n datadog
```

See `clusterrole-fix.yaml` for the patch.

### Option 3: Update Helm Values

If using custom Helm values, remove `controllerrevisions`:

```yaml
clusterAgent:
  confd:
    kubernetes_state_core.yaml: |-
      # Remove controllerrevisions from collectors list
```

Then re-deploy:

```bash
helm upgrade datadog-operator datadog/datadog-operator -n datadog -f values.yaml
```

## Files

- `README.md` - This guide
- `clusterrole-fix.yaml` - ClusterRole patch with controllerrevisions permission
- `diagnose.sh` - Automated diagnostic script

## Prevention

When adding custom collectors to `kubernetes_state_core`:

1. ✅ Check if the resource requires special permissions
2. ✅ Update the ClusterRole accordingly
3. ✅ Test in a dev environment first
4. ✅ Document in your GitOps repository

## Related Resources

- [Datadog Operator Documentation](https://github.com/DataDog/datadog-operator)
- [kubernetes_state_core Integration](https://docs.datadoghq.com/integrations/kubernetes_state_core/)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

## Key Learnings

1. ✅ ControllerRevisions exist in Kubernetes by default
2. ❌ They are NOT in the default collectors list
3. ⚠️ Custom configuration must match ClusterRole permissions
4. 🔧 ConfigMap is operator-managed and safe to regenerate
5. 📋 Always check for GitOps when investigating config issues
