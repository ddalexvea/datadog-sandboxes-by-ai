#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Verifying kubernetes_state_core Issue                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Get cluster agent pod
CLUSTER_AGENT_POD=$(kubectl get pods -n datadog \
  -l app.kubernetes.io/component=cluster-agent \
  -o name | head -1)

if [ -z "$CLUSTER_AGENT_POD" ]; then
    echo "❌ No cluster agent pod found"
    exit 1
fi

echo "📊 Checking kubernetes_state_core check status..."
echo ""

kubectl exec -n datadog "$CLUSTER_AGENT_POD" -- agent status 2>&1 | \
  grep -A 25 "kubernetes_state_core" || true

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check for the error
if kubectl exec -n datadog "$CLUSTER_AGENT_POD" -- agent status 2>&1 | \
   grep -q "resource controllerrevisions does not exist"; then
    echo "🔴 ISSUE REPRODUCED!"
    echo ""
    echo "The check is failing with:"
    echo "  Error: resource controllerrevisions does not exist"
    echo ""
    echo "Expected behavior:"
    echo "  ❌ Status: [ERROR]"
    echo "  ❌ Metric Samples: 0"
    echo "  ❌ Last Successful Execution: Never"
    echo ""
    echo "Next step: Apply fix"
    echo "  ./apply-fix.sh"
else
    echo "⚠️  Issue not reproduced or already fixed"
    echo ""
    echo "Check status above. If showing [OK], the issue is not present."
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Additional verification
echo "🔍 Additional Checks:"
echo ""

echo "1. ControllerRevisions exist in cluster:"
kubectl api-resources | grep controllerrevisions
kubectl get controllerrevisions -A | head -5

echo ""
echo "2. Cluster Agent can access controllerrevisions:"
kubectl auth can-i list controllerrevisions \
  --as=system:serviceaccount:datadog:datadog-cluster-agent -A

echo ""
echo "3. ConfigMap content:"
kubectl get configmap datadog-kube-state-metrics-core-config -n datadog \
  -o jsonpath='{.data.kubernetes_state_core\.yaml\.default}' | \
  grep -A 2 -B 2 "controllerrevisions" || echo "  controllerrevisions not found in config"

echo ""
