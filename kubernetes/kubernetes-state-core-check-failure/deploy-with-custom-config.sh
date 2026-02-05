#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Deploying Datadog with Custom ConfigMap (Issue Reproduction)║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Check for API keys
if [ -z "$DD_API_KEY" ]; then
    echo "❌ DD_API_KEY environment variable is required"
    echo "   Export it with: export DD_API_KEY='your-key'"
    exit 1
fi

if [ -z "$DD_APP_KEY" ]; then
    echo "⚠️  DD_APP_KEY not set (optional for this reproduction)"
    DD_APP_KEY="placeholder"
fi

echo "✅ API keys configured"
echo ""

# Create secret with API keys
echo "🔐 Creating Datadog secrets..."
kubectl create secret generic datadog-secrets \
  --from-literal=api-key="$DD_API_KEY" \
  --from-literal=app-key="$DD_APP_KEY" \
  --namespace=datadog \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""

# Deploy DatadogAgent CR
echo "📋 Deploying DatadogAgent CR..."
kubectl apply -f datadog-agent-spec.yaml

echo ""
echo "⏳ Waiting for agent pods to start (30 seconds)..."
sleep 30

# Deploy custom ConfigMap with controllerrevisions
echo "🔧 Deploying custom ConfigMap with controllerrevisions..."
kubectl apply -f custom-configmap.yaml

echo ""
echo "♻️  Restarting cluster agent to pick up custom ConfigMap..."
kubectl rollout restart deployment/datadog-cluster-agent -n datadog

echo ""
echo "⏳ Waiting for rollout to complete..."
kubectl rollout status deployment/datadog-cluster-agent -n datadog --timeout=120s

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Deployment Complete! ✅                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "The issue should now be reproduced."
echo ""
echo "Next step: Run verification script"
echo "  ./verify-issue.sh"
