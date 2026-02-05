#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            Applying Fix for kubernetes_state_core            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "Choose a solution:"
echo ""
echo "1) Delete ConfigMap (Recommended - removes controllerrevisions)"
echo "2) Add ClusterRole Permission (keeps controllerrevisions)"
echo "3) Both (add permission then show how to remove from config)"
echo ""
read -p "Enter choice [1-3]: " choice

case $choice in
    1)
        echo ""
        echo "🔄 Solution 1: Delete ConfigMap"
        echo "   The operator will regenerate it with correct defaults"
        echo ""
        
        echo "Deleting ConfigMap..."
        kubectl delete configmap datadog-kube-state-metrics-core-config -n datadog
        
        echo "Waiting for operator to recreate (10 seconds)..."
        sleep 10
        
        echo "Restarting cluster agent..."
        kubectl rollout restart deployment/datadog-cluster-agent -n datadog
        
        echo "Waiting for rollout..."
        kubectl rollout status deployment/datadog-cluster-agent -n datadog --timeout=120s
        ;;
        
    2)
        echo ""
        echo "🔧 Solution 2: Add ClusterRole Permission"
        echo "   This allows the agent to access controllerrevisions"
        echo ""
        
        echo "Applying ClusterRole fix..."
        kubectl apply -f clusterrole-fix.yaml
        
        echo "Restarting cluster agent..."
        kubectl rollout restart deployment/datadog-cluster-agent -n datadog
        
        echo "Waiting for rollout..."
        kubectl rollout status deployment/datadog-cluster-agent -n datadog --timeout=120s
        ;;
        
    3)
        echo ""
        echo "🔧 Solution 3: Add Permission + Show Config Removal"
        echo ""
        
        echo "Step 1: Adding ClusterRole permission..."
        kubectl apply -f clusterrole-fix.yaml
        
        echo "Restarting cluster agent..."
        kubectl rollout restart deployment/datadog-cluster-agent -n datadog
        
        echo "Waiting for rollout..."
        kubectl rollout status deployment/datadog-cluster-agent -n datadog --timeout=120s
        
        echo ""
        echo "✅ Permission added and check should now work!"
        echo ""
        echo "Step 2: To remove controllerrevisions from config (optional):"
        echo ""
        echo "  # Delete the custom ConfigMap"
        echo "  kubectl delete configmap datadog-kube-state-metrics-core-config -n datadog"
        echo ""
        echo "  # Restart to use regenerated default config"
        echo "  kubectl rollout restart deployment/datadog-cluster-agent -n datadog"
        echo ""
        ;;
        
    *)
        echo "❌ Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Wait a moment for the check to run
echo "⏳ Waiting 30 seconds for check to run..."
sleep 30

# Verify fix
echo "🔍 Verifying fix..."
echo ""

CLUSTER_AGENT_POD=$(kubectl get pods -n datadog \
  -l app.kubernetes.io/component=cluster-agent \
  -o name | head -1)

kubectl exec -n datadog "$CLUSTER_AGENT_POD" -- agent status 2>&1 | \
  grep -A 15 "kubernetes_state_core"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                 Fix Applied! ✅                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Check if fixed
if kubectl exec -n datadog "$CLUSTER_AGENT_POD" -- agent status 2>&1 | \
   grep -q "kubernetes_state_core.*\[OK\]"; then
    echo "✅ SUCCESS! Check is now working"
    echo ""
    echo "Expected to see:"
    echo "  ✅ Status: [OK]"
    echo "  ✅ Metric Samples: 600+"
    echo "  ✅ Last Successful Execution: Recent timestamp"
else
    echo "⚠️  Check status unclear. Review output above."
    echo ""
    echo "If still showing [ERROR], wait a bit longer and check again:"
    echo "  kubectl exec -n datadog \$POD -- agent status | grep -A 15 kubernetes_state_core"
fi

echo ""
