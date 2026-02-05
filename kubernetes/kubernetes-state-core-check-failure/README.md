# kubernetes_state_core Check Failing After Operator Upgrade

## Issue Summary

After upgrading Datadog Operator from 2.12.0 to 2.17.0, the `kubernetes_state_core` check fails with error:

```
Error: resource controllerrevisions does not exist. Available resources: ...
```

**Impact:** Complete loss of Kubernetes state metrics (0 metrics collected)

## Environment

- **Kubernetes**: EKS
- **Datadog Operator**: 2.17.0 (upgraded from 2.12.0)
- **Agent Version**: 7.68.2
- **Deployment Method**: Datadog Operator (Helm)
- **GitOps**: ArgoCD

## Root Cause

The ConfigMap `datadog-kube-state-metrics-core-config` contains `controllerrevisions` in the collectors list, but the ClusterRole `datadog-cluster-agent` is missing the necessary RBAC permissions to access this resource.

This is caused by custom configuration (via Helm values, ArgoCD, or manual edit) that adds `controllerrevisions` without the corresponding ClusterRole permission.

## Prerequisites

- EKS cluster (t3.medium nodes recommended)
- AWS credentials configured
- `kubectl`, `helm`, `eksctl` installed
- Optional: `aws-vault` for credential management

## Quick Reproduction

```bash
# 1. Setup
./setup.sh

# 2. Deploy with custom config (simulates customer environment)
./deploy-with-custom-config.sh

# 3. Verify the issue
./verify-issue.sh

# 4. Apply fix
./apply-fix.sh

# 5. Cleanup
./cleanup.sh
```

## Files

- `setup.sh` - Create EKS cluster and install Datadog Operator
- `deploy-with-custom-config.sh` - Deploy with controllerrevisions in config
- `verify-issue.sh` - Verify kubernetes_state_core is failing
- `apply-fix.sh` - Three solution options
- `cleanup.sh` - Delete all resources
- `datadog-agent-spec.yaml` - Customer's DatadogAgent CR
- `custom-configmap.yaml` - ConfigMap with controllerrevisions
- `clusterrole-fix.yaml` - Updated ClusterRole with permission

## Solution Options

### Option 1: Delete ConfigMap (Recommended)

Let the operator regenerate with correct defaults:

```bash
kubectl delete configmap datadog-kube-state-metrics-core-config -n datadog
kubectl rollout restart deployment/datadog-cluster-agent -n datadog
```

### Option 2: Add ClusterRole Permission

Keep controllerrevisions and add permission:

```bash
kubectl apply -f clusterrole-fix.yaml
kubectl rollout restart deployment/datadog-cluster-agent -n datadog
```

### Option 3: Remove from Custom Config

Update your Helm values/ArgoCD config to remove controllerrevisions.

## Verification

After applying fix:

```bash
kubectl exec -n datadog $(kubectl get pods -n datadog \
  -l app.kubernetes.io/component=cluster-agent -o name | head -1) \
  -- agent status | grep -A 15 kubernetes_state_core
```

Expected output:
```
kubernetes_state_core
---------------------
  Instance ID: kubernetes_state_core:... [OK]
  Total Runs: <increasing>
  Metric Samples: Last Run: 660+
  Last Successful Execution Date: <recent timestamp>
```

## Related Links

- [Ticket 2487328](https://datadog.zendesk.com/agent/tickets/2487328)
- [Datadog Operator Documentation](https://github.com/DataDog/datadog-operator)
- [kubernetes_state_core Integration](https://docs.datadoghq.com/integrations/kubernetes_state_core/)

## Key Learnings

1. ✅ ControllerRevisions exist in EKS/Kubernetes by default
2. ❌ They are NOT in the default collectors list (Agent 7.68.2 + Operator 2.17.0)
3. ⚠️ Custom configuration must match ClusterRole permissions
4. 🔧 ConfigMap is operator-managed and can be safely regenerated
5. 📋 Always check for ArgoCD/GitOps when investigating configuration issues
