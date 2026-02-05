#!/bin/bash

# Cleanup script for ECS Fargate Network Path demo
# Author: Alexandre VEA

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
export AWS_PROFILE="${AWS_PROFILE:-your-aws-profile}"
export AWS_REGION="us-east-1"
CLUSTER_NAME="netpath-fargate-cluster"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  ECS Fargate Cleanup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Stop all running tasks
echo -e "${YELLOW}Stopping all tasks in cluster...${NC}"
TASK_ARNS=$(aws ecs list-tasks \
    --cluster $CLUSTER_NAME \
    --region $AWS_REGION \
    --query 'taskArns[]' \
    --output text)

if [ -n "$TASK_ARNS" ]; then
    for TASK_ARN in $TASK_ARNS; do
        echo "  Stopping task: $TASK_ARN"
        aws ecs stop-task \
            --cluster $CLUSTER_NAME \
            --task $TASK_ARN \
            --region $AWS_REGION > /dev/null
    done
    echo -e "${GREEN}✅ All tasks stopped${NC}"
else
    echo -e "${GREEN}✅ No running tasks${NC}"
fi
echo ""

# Wait for tasks to stop
echo -e "${YELLOW}Waiting for tasks to stop...${NC}"
sleep 10

# Delete cluster
echo -e "${YELLOW}Deleting ECS cluster...${NC}"
aws ecs delete-cluster \
    --cluster $CLUSTER_NAME \
    --region $AWS_REGION > /dev/null 2>&1 || echo "  Cluster already deleted or doesn't exist"
echo -e "${GREEN}✅ Cluster deleted${NC}"
echo ""

# Delete security group
echo -e "${YELLOW}Deleting security group...${NC}"
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --region $AWS_REGION \
    --query 'Vpcs[0].VpcId' \
    --output text)

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=fargate-netpath-demo-sg" "Name=vpc-id,Values=$VPC_ID" \
    --region $AWS_REGION \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [ "$SG_ID" != "None" ] && [ "$SG_ID" != "" ]; then
    aws ec2 delete-security-group \
        --group-id $SG_ID \
        --region $AWS_REGION 2>/dev/null || echo "  Security group in use or already deleted"
    echo -e "${GREEN}✅ Security group deleted${NC}"
else
    echo -e "${GREEN}✅ Security group not found${NC}"
fi
echo ""

# Delete log groups
echo -e "${YELLOW}Deleting CloudWatch log groups...${NC}"
LOG_GROUPS=(
    "/ecs/fargate-netpath/nginx"
    "/ecs/fargate-netpath/datadog-agent"
    "/ecs/fargate-netpath/config-init"
)

for LOG_GROUP in "${LOG_GROUPS[@]}"; do
    aws logs delete-log-group \
        --log-group-name $LOG_GROUP \
        --region $AWS_REGION 2>/dev/null || echo "  Log group $LOG_GROUP not found"
done
echo -e "${GREEN}✅ Log groups deleted${NC}"
echo ""

# Restore backup files
echo -e "${YELLOW}Restoring backup files...${NC}"
if [ -f "task-definition-network-path.json.bak" ]; then
    mv task-definition-network-path.json.bak task-definition-network-path.json
    echo -e "${GREEN}✅ Restored task-definition-network-path.json${NC}"
fi
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ✅ Cleanup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
