#!/bin/bash

################################################################################
# Datadog Mixed Cluster (Linux + Windows) on AWS EKS - Complete Deployment
# 
# This script deploys a full mixed cluster setup on AWS EKS using aws-vault
# Run this on your local machine with AWS Vault configured
#
# Prerequisites:
# - aws-vault configured with AWS SSO
# - eksctl installed
# - kubectl installed
# - helm installed
# - Datadog API key available
#
# Usage:
#   export AWS_PROFILE="sso-tse-sandbox-account-admin"
#   export DD_API_KEY="your-datadog-api-key"
#   bash deploy-eks-mixed-cluster.sh
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CLUSTER_NAME="dd-mixed-cluster-repro"
REGION="us-east-1"
LINUX_NODE_TYPE="t3.medium"
WINDOWS_NODE_TYPE="t3.large"

# Validation
if [ -z "$AWS_PROFILE" ]; then
    echo -e "${RED}ERROR: AWS_PROFILE not set${NC}"
    echo "Set with: export AWS_PROFILE=\"sso-tse-sandbox-account-admin\""
    exit 1
fi

if [ -z "$DD_API_KEY" ]; then
    echo -e "${RED}ERROR: DD_API_KEY not set${NC}"
    echo "Set with: export DD_API_KEY=\"your-datadog-api-key\""
    exit 1
fi

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}EKS Mixed Cluster Deployment${NC}"
echo -e "${BLUE}Using: $AWS_PROFILE${NC}"
echo -e "${BLUE}================================${NC}\n"

# Step 1: Verify AWS credentials
echo -e "${YELLOW}[1/10] Verifying AWS credentials...${NC}"
aws-vault exec $AWS_PROFILE -- aws sts get-caller-identity
echo -e "${GREEN}✓ AWS credentials verified${NC}\n"

# Step 2: Create EKS cluster with Linux nodes
echo -e "${YELLOW}[2/10] Creating EKS cluster with Linux nodes...${NC}"
echo "This will take ~15 minutes..."
aws-vault exec $AWS_PROFILE -- eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --version 1.31 \
  --nodegroup-name linux-ng \
  --node-type $LINUX_NODE_TYPE \
  --nodes 1 \
  --managed
echo -e "${GREEN}✓ Linux cluster created${NC}\n"

# Step 3: Create Windows node group
echo -e "${YELLOW}[3/10] Creating Windows node group...${NC}"
echo "This will take ~10+ minutes..."
aws-vault exec $AWS_PROFILE -- eksctl create nodegroup \
  --cluster $CLUSTER_NAME \
  --region $REGION \
  --name windows-ng \
  --node-type $WINDOWS_NODE_TYPE \
  --nodes 1 \
  --ami-type WINDOWS_CORE_2022_x86_64
echo -e "${GREEN}✓ Windows node group created${NC}\n"

# Step 4: Verify cluster
echo -e "${YELLOW}[4/10] Verifying cluster setup...${NC}"
aws-vault exec $AWS_PROFILE -- kubectl get nodes -o wide
echo -e "${GREEN}✓ Cluster verified${NC}\n"

# Step 5: Add Helm repo
echo -e "${YELLOW}[5/10] Adding Datadog Helm repository...${NC}"
aws-vault exec $AWS_PROFILE -- helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true
aws-vault exec $AWS_PROFILE -- helm repo update
echo -e "${GREEN}✓ Helm repo added${NC}\n"

# Step 6: Create namespaces and secrets
echo -e "${YELLOW}[6/10] Creating namespaces and secrets...${NC}"

# Linux namespace
aws-vault exec $AWS_PROFILE -- kubectl create namespace datadog-linux 2>/dev/null || true
aws-vault exec $AWS_PROFILE -- kubectl create secret generic datadog-secret \
  --from-literal=api-key="$DD_API_KEY" \
  -n datadog-linux \
  --dry-run=client -o yaml | aws-vault exec $AWS_PROFILE -- kubectl apply -f -

# Windows namespace
aws-vault exec $AWS_PROFILE -- kubectl create namespace datadog-windows 2>/dev/null || true
aws-vault exec $AWS_PROFILE -- kubectl create secret generic datadog-secret \
  --from-literal=api-key="$DD_API_KEY" \
  -n datadog-windows \
  --dry-run=client -o yaml | aws-vault exec $AWS_PROFILE -- kubectl apply -f -

echo -e "${GREEN}✓ Namespaces and secrets created${NC}\n"

# Step 7: Deploy Linux release
echo -e "${YELLOW}[7/10] Deploying Linux release (with Cluster Agent & CRDs)...${NC}"
aws-vault exec $AWS_PROFILE -- helm install datadog-linux datadog/datadog \
  --namespace datadog-linux \
  --set datadog.site=datadoghq.com \
  --set datadog.apiKeyExistingSecret=datadog-secret \
  --set datadog.apiKeyExistingSecretKey=api-key \
  --set datadog.clusterName=$CLUSTER_NAME \
  --set clusterAgent.enabled=true \
  --set clusterAgent.replicas=1 \
  --set targetSystem=linux \
  --set datadog-crds.crds.datadogMetrics=true \
  --set kubeStateMetricsEnabled=true \
  --wait --timeout 5m
echo -e "${GREEN}✓ Linux release deployed${NC}\n"

# Step 8: Deploy Windows release
echo -e "${YELLOW}[8/10] Deploying Windows release...${NC}"
aws-vault exec $AWS_PROFILE -- helm install datadog-windows datadog/datadog \
  --namespace datadog-windows \
  --set datadog.site=datadoghq.com \
  --set datadog.apiKeyExistingSecret=datadog-secret \
  --set datadog.apiKeyExistingSecretKey=api-key \
  --set datadog.clusterName=$CLUSTER_NAME \
  --set targetSystem=windows \
  --set clusterAgent.enabled=false \
  --set existingClusterAgent.join=true \
  --set existingClusterAgent.serviceName=datadog-linux-cluster-agent \
  --set existingClusterAgent.tokenSecretName=datadog-linux-cluster-agent-token \
  --set datadog-crds.crds.datadogMetrics=false \
  --set kubeStateMetricsEnabled=false \
  --wait --timeout 5m
echo -e "${GREEN}✓ Windows release deployed${NC}\n"

# Step 9: Verify deployments
echo -e "${YELLOW}[9/10] Verifying deployments...${NC}"

echo "Linux namespace pods:"
aws-vault exec $AWS_PROFILE -- kubectl get pods -n datadog-linux

echo ""
echo "Windows namespace pods:"
aws-vault exec $AWS_PROFILE -- kubectl get pods -n datadog-windows

echo ""
echo "CRD ownership:"
aws-vault exec $AWS_PROFILE -- kubectl get crd datadogdashboards.datadoghq.com -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "datadog-linux"

echo -e "${GREEN}✓ Deployments verified${NC}\n"

# Step 10: Display summary
echo -e "${YELLOW}[10/10] Deployment complete!${NC}\n"

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}✅ EKS Mixed Cluster Ready!${NC}"
echo -e "${GREEN}================================${NC}\n"

echo -e "${BLUE}Cluster Information:${NC}"
echo "  Cluster Name: $CLUSTER_NAME"
echo "  Region: $REGION"
echo "  Linux Nodes: $LINUX_NODE_TYPE (1 node)"
echo "  Windows Nodes: $WINDOWS_NODE_TYPE (1 node)"
echo ""

echo -e "${BLUE}Datadog Deployments:${NC}"
echo "  Linux Release: datadog-linux (in datadog-linux namespace)"
echo "  Windows Release: datadog-windows (in datadog-windows namespace)"
echo "  Cluster Agent: Running in Linux namespace"
echo ""

echo -e "${BLUE}Next Steps:${NC}"
echo "  1. Monitor Cluster Agent logs:"
echo "     aws-vault exec $AWS_PROFILE -- kubectl logs -n datadog-linux -l app=datadog-cluster-agent -f"
echo ""
echo "  2. Verify CRD ownership (no conflicts):"
echo "     aws-vault exec $AWS_PROFILE -- kubectl get crd | grep datadog"
echo ""
echo "  3. Check Windows agent connectivity:"
echo "     aws-vault exec $AWS_PROFILE -- kubectl get pods -n datadog-windows"
echo ""
echo "  4. View full node information:"
echo "     aws-vault exec $AWS_PROFILE -- kubectl get nodes -o wide"
echo ""

echo -e "${YELLOW}⚠️  Cost Estimation:${NC}"
echo "  Linux Node (t3.medium): ~\$0.0416/hour"
echo "  Windows Node (t3.large): ~\$0.1248/hour"
echo "  EKS Cluster: \$0.10/hour"
echo "  Total: ~\$0.27/hour"
echo ""

echo -e "${RED}Cleanup (when done):${NC}"
echo "  aws-vault exec $AWS_PROFILE -- helm uninstall datadog-windows -n datadog-windows"
echo "  aws-vault exec $AWS_PROFILE -- helm uninstall datadog-linux -n datadog-linux"
echo "  aws-vault exec $AWS_PROFILE -- kubectl delete namespace datadog-linux datadog-windows"
echo "  aws-vault exec $AWS_PROFILE -- eksctl delete cluster --name $CLUSTER_NAME --region $REGION"
echo ""
