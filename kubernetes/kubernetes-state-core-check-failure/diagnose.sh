#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Diagnosing kubernetes_state_core Check Issue            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Get cluster agent pod
CLUSTER_AGENT_POD=$(kubectl get pods -n datadog \
  -l app.kubernetes.io/component=cluster-agent \
  -o name 2>/dev/null | head -1)

if [ -z "$CLUSTER_AGENT_POD" ]; then
    echo "❌ No cluster agent pod found"
    echo "   Make sure Datadog is deployed with cluster agent enabled"
    exit 1
fi

echo "✅ Found cluster agent: $CLUSTER_AGENT_POD"
echo ""

# Check 1: Agent status
echo "═══════════════════════════════════════════════════════════════"
echo "1️⃣  Checking kubernetes_state_core status..."
echo "═══════════════════════════════════════════════════════════════"
echo ""

kubectl exec -n datadog "$CLUSTER_AGENT_POD" -- agent status 2>&1 | \
  grep -A 20 "kubernetes_state_core" || echo "⚠️  Could not find kubernetes_state_core in agent status"

echo ""

# Check 2: ConfigMap content
echo "═══════════════════════════════════════════════════════════════"
echo "2️⃣  Checking if controllerrevisions is in config..."
echo "═══════════════════════════════════════════════════════════════"
echo ""

if kubectl get configmap datadog-kube-state-metrics-core-config -n datadog \
   -o jsonpath='{.data.kubernetes_state_core\.yaml\.default}' 2>/dev/null | \
   grep -q "controllerrevisions"; then
    echo "❌ FOUND: controllerrevisions is in the collectors list"
    echo ""
    echo "   This is the source of the problem!"
    HAS_CONTROLLERREVISIONS=true
else
    echo "✅ Good: controllerrevisions is NOT in the collectors list"
    HAS_CONTROLLERREVISIONS=false
fi

echo ""

# Check 3: ClusterRole permission
echo "═══════════════════════════════════════════════════════════════"
echo "3️⃣  Checking ClusterRole permissions..."
echo "═══════════════════════════════════════════════════════════════"
echo ""

if kubectl auth can-i list controllerrevisions \
   --as=system:serviceaccount:datadog:datadog-cluster-agent -A 2>&1 | \
   grep -q "yes"; then
    echo "✅ Cluster Agent HAS permission to list controllerrevisions"
    HAS_PERMISSION=true
else
    echo "❌ Cluster Agent does NOT have permission to list controllerrevisions"
    HAS_PERMISSION=false
fi

echo ""

# Check 4: Resource exists
echo "═══════════════════════════════════════════════════════════════"
echo "4️⃣  Verifying controllerrevisions resource exists..."
echo "═══════════════════════════════════════════════════════════════"
echo ""

if kubectl api-resources | grep -q controllerrevisions; then
    echo "✅ Resource type exists in cluster"
    echo ""
    echo "   Instances found:"
    kubectl get controllerrevisions -A 2>/dev/null | head -5
else
    echo "⚠️  Resource type not found (this is unusual)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📊 DIAGNOSIS SUMMARY"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Determine issue and solution
if [ "$HAS_CONTROLLERREVISIONS" = true ] && [ "$HAS_PERMISSION" = false ]; then
    echo "🔴 ISSUE CONFIRMED!"
    echo ""
    echo "Problem:"
    echo "  • controllerrevisions is in your config"
    echo "  • But ClusterRole lacks the permission"
    echo ""
    echo "Solutions (choose one):"
    echo ""
    echo "  A) Delete ConfigMap (Recommended):"
    echo "     kubectl delete configmap datadog-kube-state-metrics-core-config -n datadog"
    echo "     kubectl rollout restart deployment/datadog-cluster-agent -n datadog"
    echo ""
    echo "  B) Add permission (if you need controllerrevisions):"
    echo "     kubectl apply -f clusterrole-fix.yaml"
    echo "     kubectl rollout restart deployment/datadog-cluster-agent -n datadog"
    echo ""
    echo "  C) Update Helm values (if using custom values):"
    echo "     Remove controllerrevisions from kubeStateMetricsCore.conf"
    echo ""
elif [ "$HAS_CONTROLLERREVISIONS" = true ] && [ "$HAS_PERMISSION" = true ]; then
    echo "⚠️  UNEXPECTED STATE"
    echo ""
    echo "  • controllerrevisions is in config"
    echo "  • Permission exists"
    echo "  • But check is still failing?"
    echo ""
    echo "Check agent logs for more details:"
    echo "  kubectl logs -n datadog $CLUSTER_AGENT_POD --tail=100"
elif [ "$HAS_CONTROLLERREVISIONS" = false ]; then
    echo "✅ Configuration looks good!"
    echo ""
    echo "If you're still seeing errors, check:"
    echo "  • Agent logs"
    echo "  • Recent configuration changes"
    echo "  • ArgoCD or GitOps sync status"
fi

echo ""
