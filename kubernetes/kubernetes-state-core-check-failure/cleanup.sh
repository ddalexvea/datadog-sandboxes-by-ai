#!/bin/bash
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                 Cleaning Up Resources                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

CLUSTER_NAME="${CLUSTER_NAME:-ksc-issue-reproduction}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "⚠️  This will delete:"
echo "  - EKS cluster: $CLUSTER_NAME"
echo "  - All associated resources"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "🗑️  Deleting EKS cluster..."
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait

echo ""
echo "✅ Cleanup complete!"
