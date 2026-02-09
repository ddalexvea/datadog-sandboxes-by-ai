#!/bin/bash
# Helper script to verify labels on Kubernetes resources

set -e

echo "=== CHECKING DEPLOYMENT LABELS ==="
kubectl get deployment test-app-annotations -o jsonpath='{.metadata.labels}' | jq '.' || echo "Deployment not found"

echo -e "\n=== CHECKING REPLICASET LABELS ==="
kubectl get replicaset -l app=test-app-annotations --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.labels}' | jq '.' || echo "ReplicaSet not found"

echo -e "\n=== CHECKING POD LABELS ==="
kubectl get pod -l app=test-app-annotations -o jsonpath='{.items[0].metadata.labels}' | jq '.' || echo "Pod not found"

echo -e "\n=== CHECKING POD ANNOTATIONS ==="
kubectl get pod -l app=test-app-annotations -o jsonpath='{.items[0].metadata.annotations}' | jq '.' || echo "Pod not found"

echo -e "\n✅ Verification complete!"
echo "Expected: ReplicaSet should have tags.datadoghq.com/team if fix is applied"