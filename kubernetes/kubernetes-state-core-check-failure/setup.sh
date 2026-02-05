#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Setting up EKS cluster for kubernetes_state_core issue     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-ksc-issue-reproduction}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
NODE_COUNT="${NODE_COUNT:-2}"

echo "📋 Configuration:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Region: $AWS_REGION"
echo "  Node type: $NODE_TYPE"
echo "  Node count: $NODE_COUNT"
echo ""

# Check prerequisites
echo "✅ Checking prerequisites..."
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl is required"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "❌ helm is required"; exit 1; }
command -v eksctl >/dev/null 2>&1 || { echo "❌ eksctl is required"; exit 1; }
echo "✅ All prerequisites met"
echo ""

# Create EKS cluster
echo "🚀 Creating EKS cluster (this will take 15-20 minutes)..."
eksctl create cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --nodegroup-name standard-workers \
  --node-type "$NODE_TYPE" \
  --nodes "$NODE_COUNT" \
  --nodes-min 2 \
  --nodes-max 4 \
  --managed \
  --zones "${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c"

echo ""
echo "✅ EKS cluster created successfully!"
echo ""

# Update kubeconfig
echo "📝 Updating kubeconfig..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

# Verify cluster
echo "🔍 Verifying cluster..."
kubectl get nodes
echo ""

# Add Datadog Helm repo
echo "📦 Adding Datadog Helm repository..."
helm repo add datadog https://helm.datadoghq.com
helm repo update
echo ""

# Install Datadog Operator 2.17.0
echo "🎯 Installing Datadog Operator v2.17.0..."
helm install datadog-operator datadog/datadog-operator \
  --version 2.17.0 \
  --namespace datadog \
  --create-namespace \
  --wait

echo ""
echo "✅ Datadog Operator installed successfully!"
echo ""

# Verify operator
echo "🔍 Verifying operator..."
kubectl get pods -n datadog -l app.kubernetes.io/name=datadog-operator
echo ""

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete! ✅                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "1. Set your API/APP keys:"
echo "   export DD_API_KEY='your-api-key'"
echo "   export DD_APP_KEY='your-app-key'"
echo ""
echo "2. Run deployment script:"
echo "   ./deploy-with-custom-config.sh"
