#!/bin/bash

# ECS Fargate + Network Path Deployment Script
# Author: Alexandre VEA
# Date: 2026-02-04

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
export AWS_PROFILE="${AWS_PROFILE:-your-aws-profile}"
export AWS_REGION="us-east-1"
CLUSTER_NAME="netpath-fargate-cluster"
TASK_FAMILY="fargate-netpath-demo"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  ECS Fargate + Network Path Deployer${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Function to check AWS credentials
check_aws_auth() {
    echo -e "${YELLOW}[1/8] Checking AWS authentication...${NC}"
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        echo -e "${RED}❌ AWS authentication failed. Please configure AWS credentials first${NC}"
        exit 1
    fi
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    echo -e "${GREEN}✅ Authenticated as account: $ACCOUNT_ID${NC}"
    echo ""
}

# Function to prompt for API key
get_api_key() {
    echo -e "${YELLOW}[2/8] Datadog API Key Setup${NC}"
    
    if [ -z "$DD_API_KEY" ]; then
        echo -e "${YELLOW}Enter your Datadog API Key:${NC}"
        read -s DD_API_KEY
        echo ""
    fi
    
    if [ -z "$DD_API_KEY" ]; then
        echo -e "${RED}❌ No API key provided${NC}"
        exit 1
    fi
    
    # Update task definition with API key
    sed -i.bak "s/REPLACE_WITH_YOUR_API_KEY/$DD_API_KEY/g" task-definition-network-path.json
    sed -i.bak "s/ACCOUNT_ID/$ACCOUNT_ID/g" task-definition-network-path.json
    
    echo -e "${GREEN}✅ API key configured${NC}"
    echo ""
}

# Function to create ECS cluster
create_cluster() {
    echo -e "${YELLOW}[3/8] Creating ECS cluster...${NC}"
    
    if aws ecs describe-clusters \
        --clusters $CLUSTER_NAME \
        --region $AWS_REGION \
        --query 'clusters[0].status' \
        --output text 2>/dev/null | grep -q "ACTIVE"; then
        echo -e "${GREEN}✅ Cluster '$CLUSTER_NAME' already exists${NC}"
    else
        aws ecs create-cluster \
            --cluster-name $CLUSTER_NAME \
            --region $AWS_REGION \
            --capacity-providers FARGATE \
            --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1
        echo -e "${GREEN}✅ Cluster '$CLUSTER_NAME' created${NC}"
    fi
    echo ""
}

# Function to get VPC and subnet
get_network_config() {
    echo -e "${YELLOW}[4/8] Getting network configuration...${NC}"
    
    # Get default VPC
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=isDefault,Values=true" \
        --region $AWS_REGION \
        --query 'Vpcs[0].VpcId' \
        --output text)
    
    # Get first public subnet
    SUBNET_ID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
        --region $AWS_REGION \
        --query 'Subnets[0].SubnetId' \
        --output text)
    
    echo -e "${GREEN}✅ VPC: $VPC_ID${NC}"
    echo -e "${GREEN}✅ Subnet: $SUBNET_ID${NC}"
    echo ""
}

# Function to create security group
create_security_group() {
    echo -e "${YELLOW}[5/8] Creating security group...${NC}"
    
    SG_NAME="fargate-netpath-demo-sg"
    
    # Check if security group exists
    EXISTING_SG=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
        --region $AWS_REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "None")
    
    if [ "$EXISTING_SG" != "None" ] && [ "$EXISTING_SG" != "" ]; then
        SG_ID=$EXISTING_SG
        echo -e "${GREEN}✅ Using existing security group: $SG_ID${NC}"
    else
        SG_ID=$(aws ec2 create-security-group \
            --group-name $SG_NAME \
            --description "Security group for Fargate Network Path demo" \
            --vpc-id $VPC_ID \
            --region $AWS_REGION \
            --query 'GroupId' \
            --output text)
        
        # Allow all outbound traffic (required for Network Path)
        aws ec2 authorize-security-group-egress \
            --group-id $SG_ID \
            --protocol all \
            --cidr 0.0.0.0/0 \
            --region $AWS_REGION 2>/dev/null || true
        
        # Allow inbound HTTP (for nginx)
        aws ec2 authorize-security-group-ingress \
            --group-id $SG_ID \
            --protocol tcp \
            --port 80 \
            --cidr 0.0.0.0/0 \
            --region $AWS_REGION 2>/dev/null || true
        
        echo -e "${GREEN}✅ Security group created: $SG_ID${NC}"
    fi
    echo ""
}

# Function to register task definition
register_task_definition() {
    echo -e "${YELLOW}[6/8] Registering task definition...${NC}"
    
    TASK_DEF_ARN=$(aws ecs register-task-definition \
        --cli-input-json file://task-definition-network-path.json \
        --region $AWS_REGION \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)
    
    echo -e "${GREEN}✅ Task definition registered: $TASK_DEF_ARN${NC}"
    echo ""
}

# Function to run task
run_task() {
    echo -e "${YELLOW}[7/8] Running Fargate task...${NC}"
    
    TASK_ARN=$(aws ecs run-task \
        --cluster $CLUSTER_NAME \
        --task-definition $TASK_FAMILY \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
        --region $AWS_REGION \
        --query 'tasks[0].taskArn' \
        --output text)
    
    echo -e "${GREEN}✅ Task launched: $TASK_ARN${NC}"
    echo ""
    
    # Wait for task to be running
    echo -e "${YELLOW}Waiting for task to start (this may take 1-2 minutes)...${NC}"
    aws ecs wait tasks-running \
        --cluster $CLUSTER_NAME \
        --tasks $TASK_ARN \
        --region $AWS_REGION
    
    echo -e "${GREEN}✅ Task is now RUNNING${NC}"
    echo ""
}

# Function to show verification steps
show_verification() {
    echo -e "${YELLOW}[8/8] Verification & Next Steps${NC}"
    echo ""
    echo -e "${BLUE}📋 Task Details:${NC}"
    echo "   Task ARN: $TASK_ARN"
    echo "   Cluster: $CLUSTER_NAME"
    echo "   Region: $AWS_REGION"
    echo ""
    
    echo -e "${BLUE}🔍 Check Agent Logs:${NC}"
    echo "   aws logs tail /ecs/fargate-netpath/datadog-agent --region $AWS_REGION --since 5m --follow"
    echo ""
    
    echo -e "${BLUE}🔍 Check Config Init Logs:${NC}"
    echo "   aws logs tail /ecs/fargate-netpath/config-init --region $AWS_REGION --since 5m"
    echo ""
    
    echo -e "${BLUE}🔍 Check Task Status:${NC}"
    echo "   aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --region $AWS_REGION"
    echo ""
    
    echo -e "${BLUE}📊 Datadog UI:${NC}"
    echo "   1. Network Monitoring → Network Path"
    echo "   2. Infrastructure → Containers (filter: cluster_name:$CLUSTER_NAME)"
    echo "   3. Logs → Search for: service:fargate-netpath-demo"
    echo ""
    
    echo -e "${BLUE}🧹 Cleanup (when done):${NC}"
    echo "   ./cleanup.sh"
    echo ""
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ✅ Deployment Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# Main execution
main() {
    check_aws_auth
    get_api_key
    create_cluster
    get_network_config
    create_security_group
    register_task_definition
    run_task
    show_verification
}

main
