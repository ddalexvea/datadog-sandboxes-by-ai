# ECS Fargate - Tag Case Sensitivity and Docker Labels Override Issue

**Note:** All configurations are included inline in this README for easy copy-paste reproduction. Never put API keys directly in manifests - use environment variables or AWS Secrets Manager.

## Context

This sandbox reproduces a critical tagging issue in AWS ECS Fargate where:

1. **`cluster_name` is auto-discovered** from the ECS Metadata API but **NOT documented** in the official Datadog docs
2. **Docker labels and `DD_TAGS` cannot override** auto-discovered tags, causing duplicate tag values
3. **Case sensitivity** in AWS cluster names (CamelCase) conflicts with custom lowercase tags

**Impact:**
- Metrics split across multiple tag values
- Dashboards show incomplete data
- Monitors may not trigger correctly
- Query complexity increases

**Root Cause:** The Datadog Agent creates both `ecs_cluster_name` AND `cluster_name` from the ECS API, but only `ecs_cluster_name` is documented. Custom tags don't override these auto-discovered values.

## Environment

- **Agent Version:** 7.75.1
- **Platform:** AWS ECS Fargate
- **AWS Region:** us-east-1

## Schema

```mermaid
graph TB
    subgraph "AWS ECS"
        ECS[ECS Cluster: MyCluster<br/>CamelCase from AWS]
        META[Task Metadata API v4]
        TASK[Fargate Task]
    end
    
    subgraph "Datadog Agent Container"
        AGENT[Datadog Agent]
        TAGGER[Tagger Component]
        EXTRACT[workloadmeta_extract.go]
    end
    
    subgraph "Configuration"
        LABELS[Docker Labels:<br/>cluster_name: mycluster]
        DDTAGS[DD_TAGS:<br/>cluster_name: mycluster]
    end
    
    subgraph "Result"
        AUTO1[ecs_cluster_name: MyCluster<br/>✅ Documented]
        AUTO2[cluster_name: MyCluster<br/>❌ NOT Documented]
        CUSTOM[cluster_name: mycluster<br/>❌ Doesn't Override]
    end
    
    ECS --> META
    META --> AGENT
    AGENT --> EXTRACT
    EXTRACT --> AUTO1
    EXTRACT --> AUTO2
    LABELS --> CUSTOM
    DDTAGS --> CUSTOM
    
    AUTO2 -.Conflict!.- CUSTOM
    
    style AUTO2 fill:#ff6b6b
    style CUSTOM fill:#ff6b6b
```

## Quick Start

### 1. Prerequisites

```bash
# Install AWS CLI and aws-vault
brew install awscli aws-vault

# Set up AWS SSO profile
export AWS_PROFILE=your-aws-profile

# Authenticate
aws-vault login $AWS_PROFILE
aws-vault exec $AWS_PROFILE -- aws sts get-caller-identity
```

### 2. Set Environment Variables

```bash
# Required
export DD_API_KEY='your-datadog-api-key-here'
export AWS_PROFILE='your-aws-profile'

# Optional (defaults shown)
export DD_SITE="datadoghq.com"
export AWS_REGION="us-east-1"
export CLUSTER_NAME="MyCluster"
```

### 3. Deploy ECS Fargate Task

Run the deployment script:

```bash
aws-vault exec $AWS_PROFILE -- bash << 'DEPLOY_SCRIPT'
# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create ECS Cluster (CamelCase name to reproduce the issue)
aws ecs create-cluster \
  --cluster-name ${CLUSTER_NAME:-MyCluster} \
  --region ${AWS_REGION:-us-east-1} \
  --capacity-providers FARGATE \
  --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1

# Create Task Definition
cat > task-definition.json <<TASKDEF
{
  "family": "ecs-tag-test",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "datadog-agent",
      "image": "public.ecr.aws/datadog/agent:latest",
      "essential": true,
      "environment": [
        {"name": "DD_API_KEY", "value": "${DD_API_KEY}"},
        {"name": "DD_SITE", "value": "${DD_SITE:-datadoghq.com}"},
        {"name": "ECS_FARGATE", "value": "true"},
        {
          "name": "DD_DOCKER_LABELS_AS_TAGS",
          "value": "{\"com.datadoghq.tags.cluster_name\":\"cluster_name\"}"
        },
        {
          "name": "DD_TAGS",
          "value": "env:test,cluster:mycluster,cluster_name:mycluster"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/tag-test",
          "awslogs-region": "${AWS_REGION:-us-east-1}",
          "awslogs-stream-prefix": "datadog",
          "awslogs-create-group": "true"
        }
      }
    },
    {
      "name": "app",
      "image": "public.ecr.aws/docker/library/busybox:latest",
      "essential": false,
      "command": ["sh", "-c", "while true; do echo 'Running...'; sleep 30; done"],
      "dockerLabels": {
        "com.datadoghq.tags.cluster_name": "mycluster"
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/tag-test",
          "awslogs-region": "${AWS_REGION:-us-east-1}",
          "awslogs-stream-prefix": "app",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
TASKDEF

# Register Task Definition
TASK_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://task-definition.json \
  --region ${AWS_REGION:-us-east-1} \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "Task Definition ARN: $TASK_ARN"

# Get VPC and Subnet
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region ${AWS_REGION:-us-east-1})

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[0].SubnetId' \
  --output text \
  --region ${AWS_REGION:-us-east-1})

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region ${AWS_REGION:-us-east-1})

# Run Task
TASK_ID=$(aws ecs run-task \
  --cluster ${CLUSTER_NAME:-MyCluster} \
  --task-definition $TASK_ARN \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --region ${AWS_REGION:-us-east-1} \
  --query 'tasks[0].taskArn' \
  --output text)

echo "Task ARN: $TASK_ID"

# Wait for task to start
aws ecs wait tasks-running \
  --cluster ${CLUSTER_NAME:-MyCluster} \
  --tasks $TASK_ID \
  --region ${AWS_REGION:-us-east-1}

echo "✅ Task is running!"
echo "Wait 5-10 minutes for metrics to appear in Datadog"

DEPLOY_SCRIPT
```

### 4. Verify the Issue

Wait 5-10 minutes, then check Datadog:

1. **Metrics Explorer:** https://app.datadoghq.com/metric/explorer
2. **Metric:** `ecs.fargate.cpu.user`
3. **Group by:** `cluster_name`
4. **Expected:** Two separate metric streams (the bug!)

## Test Commands

### Agent Status

```bash
# Stream agent logs
aws logs tail /ecs/tag-test --follow --region us-east-1

# Check task status
aws ecs describe-tasks \
  --cluster MyCluster \
  --tasks TASK_ARN \
  --region us-east-1 \
  --include TAGS
```

### Query Metrics

```bash
# Query Datadog API (requires DD_APP_KEY)
curl -X GET "https://api.${DD_SITE}/api/v1/query?from=$(date -u -v-10M +%s)&to=$(date -u +%s)&query=avg:ecs.fargate.cpu.user{*}by{ecs_cluster_name,cluster_name}" \
  -H "DD-API-KEY: ${DD_API_KEY}" \
  -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" | jq .
```

## Expected vs Actual

| Behavior | Expected | Actual |
|----------|----------|--------|
| `ecs_cluster_name` tag | ✅ `MyCluster` (documented) | ✅ `MyCluster` |
| `cluster_name` tag | ✅ `mycluster` (custom from DD_TAGS) | ❌ **BOTH** `MyCluster` (auto) AND `mycluster` (custom) |
| Docker labels override | ✅ Should override auto-discovered tags | ❌ Creates duplicate tags instead |
| Documentation | ✅ Lists all auto-discovered tags | ❌ Missing `cluster_name` from docs |

### Screenshots

**Metrics Explorer showing split streams:**

```
Series 1: cluster_name:MyCluster   (CamelCase, auto-discovered)
Series 2: cluster_name:mycluster   (lowercase, custom tags)
```

**Observed Tags:**
```yaml
ecs_cluster_name: MyCluster        # ✅ Documented
cluster_name: MyCluster            # ❌ NOT documented!
cluster_name: mycluster            # ❌ Doesn't override
env: test
cluster: mycluster
```

## Fix / Workaround

### Workaround 1: Use Different Tag Name (Recommended)

Don't try to override `cluster_name`. Use a custom tag name instead:

```json
{
  "name": "DD_TAGS",
  "value": "env:qa,custom_cluster:mycluster,logical_cluster:mycluster"
}
```

Then update queries to use `custom_cluster:mycluster`.

### Workaround 2: Match AWS Cluster Name Case

Rename your AWS ECS cluster to lowercase:

```bash
aws ecs create-cluster --cluster-name mycluster
```

This avoids case mismatch but requires infrastructure change.

### Workaround 3: Accept Auto-Discovered Value

Remove custom `cluster_name` tags and use the auto-discovered value in all queries:

```json
{
  "name": "DD_TAGS",
  "value": "env:qa,service:my-service"
}
```

Query with `cluster_name:MyCluster` (CamelCase).

## Root Cause Analysis

### Agent Code Path

**File:** `comp/core/tagger/collectors/workloadmeta_extract.go:465-467`

```go
if task.ClusterName != "" {
    clusterTags.AddLow(tags.EcsClusterName, task.ClusterName)  // ✅ Documented
    clusterTags.AddLow(tags.ClusterName, task.ClusterName)      // ❌ NOT documented!
}
```

**Issue:** The agent creates **BOTH** tags, but only `ecs_cluster_name` is documented in the [official AWS Fargate integration docs](https://docs.datadoghq.com/integrations/aws-fargate/?tab=webui#out-of-the-box-tags).

### Documentation Gap

**Official Docs List:**
- `ecs_cluster_name` ✅
- `container_name` ✅
- `container_id` ✅
- `docker_image` ✅
- `image_name` ✅
- `short_image` ✅
- `image_tag` ✅

**Missing from Docs:**
- `cluster_name` ❌ (auto-discovered but not documented!)

This leads users to believe they can use `cluster_name` as a custom tag.

## Troubleshooting

```bash
# Check cluster
aws ecs describe-clusters --clusters MyCluster --region us-east-1

# List tasks
aws ecs list-tasks --cluster MyCluster --region us-east-1

# Task details
aws ecs describe-tasks \
  --cluster MyCluster \
  --tasks TASK_ARN \
  --region us-east-1 \
  --include TAGS

# Container logs
aws logs tail /ecs/tag-test --since 10m --region us-east-1

# Filter for tag-related logs
aws logs tail /ecs/tag-test \
  --since 10m \
  --filter-pattern "cluster_name" \
  --region us-east-1

# Get events
aws ecs describe-tasks \
  --cluster MyCluster \
  --tasks TASK_ARN \
  --region us-east-1 \
  --query 'tasks[0].stoppedReason'
```

## Cleanup

```bash
export AWS_PROFILE=your-aws-profile
export AWS_REGION=us-east-1
export CLUSTER_NAME=MyCluster

aws-vault exec $AWS_PROFILE -- bash << 'CLEANUP'
# Stop tasks
TASKS=$(aws ecs list-tasks --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --query 'taskArns[]' --output text)
for TASK in $TASKS; do
  aws ecs stop-task --cluster ${CLUSTER_NAME} --task $TASK --region ${AWS_REGION}
done

# Wait for tasks to stop
sleep 10

# Deregister task definitions
TASK_DEFS=$(aws ecs list-task-definitions --family-prefix ecs-tag-test --region ${AWS_REGION} --query 'taskDefinitionArns[]' --output text)
for TD in $TASK_DEFS; do
  aws ecs deregister-task-definition --task-definition $TD --region ${AWS_REGION}
done

# Delete cluster
aws ecs delete-cluster --cluster ${CLUSTER_NAME} --region ${AWS_REGION}

# Delete log group
aws logs delete-log-group --log-group-name "/ecs/tag-test" --region ${AWS_REGION}

echo "✅ Cleanup complete!"
CLEANUP
```

## References

- **Datadog AWS Fargate Docs:** https://docs.datadoghq.com/integrations/aws-fargate/?tab=webui#out-of-the-box-tags
- **Agent Source Code:** [workloadmeta_extract.go](https://github.com/DataDog/datadog-agent/blob/main/comp/core/tagger/collectors/workloadmeta_extract.go#L465-L467)
- **ECS Task Metadata Endpoint:** https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-metadata-endpoint-v4.html

## Documentation Issues Identified

1. **`cluster_name` not documented** as an auto-discovered tag
2. **No tag precedence rules** explained (auto-discovered vs custom)
3. **No override behavior** documented
4. **Missing warnings** about using reserved tag names

**Recommended Documentation Updates:**
- Add `cluster_name` to out-of-the-box tags table
- Add section on "Tag Precedence and Overrides"
- Add warnings in examples about tag conflicts
- Clarify which tags can/cannot be overridden
