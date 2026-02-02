# Datadog Mixed Cluster (Linux + Windows) on AWS EKS

This sandbox reproduces the issue of deploying Datadog Agents on a mixed AWS EKS cluster (Linux + Windows nodes) and demonstrates the CRD conflict resolution using separate namespaces.

## 🚀 One-Command Deployment

```bash
# Download and run the automated script
curl -fsSL https://raw.githubusercontent.com/ddalexvea/datadog-sandboxes-by-ai/main/kubernetes/eks-mixed-cluster/deploy-eks-mixed-cluster.sh | \
  AWS_PROFILE=sso-tse-sandbox-account-admin DD_API_KEY=your-api-key bash
```

Or clone and run locally:

```bash
export AWS_PROFILE="sso-tse-sandbox-account-admin"
export DD_API_KEY="your-datadog-api-key"
bash deploy-eks-mixed-cluster.sh
```

**Time:** ~30-40 minutes | **Cost:** ~$0.27/hour

---

## Context

When deploying Datadog Agents to a mixed EKS cluster with both Linux and Windows nodes, users encounter a Helm CustomResourceDefinition (CRD) ownership conflict if attempting to deploy two separate Helm releases **in the same namespace**. This sandbox demonstrates the problem and the recommended solution using AWS EKS infrastructure.

**Problem:** Two separate Helm releases in the same namespace compete for CRD ownership:
```
Error: unable to continue with install: CustomResourceDefinition exists and cannot be imported 
into the current release: invalid ownership metadata
```

**Solution:** Deploy releases in separate namespaces with proper cross-namespace connectivity.

## Environment

| Component | Version/Details |
|-----------|--------------------|
| **AWS Service** | EKS (Elastic Kubernetes Service) |
| **Kubernetes** | 1.31+ |
| **Linux Nodes** | Amazon Linux 2, t3.medium |
| **Windows Nodes** | Windows Server 2022, t3.large |
| **Datadog Helm Chart** | 3.164.1+ |
| **Datadog Agent** | 7.x |
| **Region** | us-east-1 (configurable) |
| **Authentication** | AWS Vault |
| **AWS Profile** | sso-tse-sandbox-account-admin |

**Commands to verify:**

```bash
# List AWS profiles
aws-vault list

# Get cluster info
aws-vault exec sso-tse-sandbox-account-admin -- kubectl cluster-info

# List nodes
aws-vault exec sso-tse-sandbox-account-admin -- kubectl get nodes -o wide
```

## Architecture

```
AWS EKS Cluster (dd-mixed-cluster-repro)
│
├─ Node Group: linux-ng (Amazon Linux 2)
│  └─ Taint: os=linux:NoSchedule
│     └─ Label: kubernetes.io/os=linux
│
├─ Node Group: windows-ng (Windows Server 2022)
│  └─ Taint: os=windows:NoSchedule
│     └─ Label: kubernetes.io/os=windows
│
├─ Namespace: datadog-linux
│  ├─ Release: datadog-linux
│  ├─ CRDs (Single Instance)
│  ├─ Cluster Agent
│  └─ Linux Agent DaemonSet
│
└─ Namespace: datadog-windows
   ├─ Release: datadog-windows
   ├─ Connects to Linux Cluster Agent (cross-namespace)
   └─ Windows Agent DaemonSet
```

## Quick Start

### 0. Authenticate with AWS Vault

```bash
# Set AWS profile
export AWS_PROFILE=sso-tse-sandbox-account-admin

# Login to AWS SSO (opens browser)
aws-vault login $AWS_PROFILE

# Verify credentials
aws-vault exec $AWS_PROFILE -- aws sts get-caller-identity
```

**Output should show your AWS account ID and user.**

### 1. Create EKS Cluster with Linux Nodes

```bash
aws-vault exec $AWS_PROFILE -- eksctl create cluster \
  --name dd-mixed-cluster-repro \
  --region us-east-1 \
  --version 1.31 \
  --nodegroup-name linux-ng \
  --node-type t3.medium \
  --nodes 1 \
  --managed
```

**Wait for cluster creation (~15 minutes)**

### 2. Create Windows Node Group

```bash
aws-vault exec $AWS_PROFILE -- eksctl create nodegroup \
  --cluster dd-mixed-cluster-repro \
  --region us-east-1 \
  --name windows-ng \
  --node-type t3.large \
  --nodes 1 \
  --ami-type WINDOWS_CORE_2022_x86_64
```

**Wait for Windows node creation (~10 minutes)**

### 3. Verify Cluster Setup

```bash
# Get nodes
aws-vault exec $AWS_PROFILE -- kubectl get nodes -o wide

# Expected output:
# NAME                            STATUS   ROLES    OS
# ip-xxxxx.ec2.internal           Ready    <none>   linux
# ip-xxxxx.ec2.internal           Ready    <none>   windows
```

### 4. Add Helm Repository

```bash
aws-vault exec $AWS_PROFILE -- helm repo add datadog https://helm.datadoghq.com
aws-vault exec $AWS_PROFILE -- helm repo update
```

### 5. Create Namespaces and Secrets

```bash
# Linux namespace
aws-vault exec $AWS_PROFILE -- kubectl create namespace datadog-linux

export DD_API_KEY="your-datadog-api-key"
aws-vault exec $AWS_PROFILE -- kubectl create secret generic datadog-secret \
  --from-literal=api-key="$DD_API_KEY" \
  -n datadog-linux

# Windows namespace
aws-vault exec $AWS_PROFILE -- kubectl create namespace datadog-windows

aws-vault exec $AWS_PROFILE -- kubectl create secret generic datadog-secret \
  --from-literal=api-key="$DD_API_KEY" \
  -n datadog-windows
```

### 6. Deploy Linux Release (with Cluster Agent & CRDs)

```bash
aws-vault exec $AWS_PROFILE -- helm install datadog-linux datadog/datadog \
  --namespace datadog-linux \
  --set datadog.site=datadoghq.com \
  --set datadog.apiKeyExistingSecret=datadog-secret \
  --set datadog.apiKeyExistingSecretKey=api-key \
  --set datadog.clusterName=mixed-cluster-eks \
  --set clusterAgent.enabled=true \
  --set clusterAgent.replicas=1 \
  --set targetSystem=linux \
  --set datadog-crds.crds.datadogMetrics=true \
  --set kubeStateMetricsEnabled=true \
  --wait --timeout 5m
```

### 7. Deploy Windows Release (in different namespace)

```bash
aws-vault exec $AWS_PROFILE -- helm install datadog-windows datadog/datadog \
  --namespace datadog-windows \
  --set datadog.site=datadoghq.com \
  --set datadog.apiKeyExistingSecret=datadog-secret \
  --set datadog.apiKeyExistingSecretKey=api-key \
  --set datadog.clusterName=mixed-cluster-eks \
  --set targetSystem=windows \
  --set clusterAgent.enabled=false \
  --set existingClusterAgent.join=true \
  --set existingClusterAgent.serviceName=datadog-linux-cluster-agent \
  --set existingClusterAgent.tokenSecretName=datadog-linux-cluster-agent-token \
  --set datadog-crds.crds.datadogMetrics=false \
  --set kubeStateMetricsEnabled=false \
  --wait --timeout 5m
```

### 8. Verify Deployments

```bash
# Check Linux namespace
aws-vault exec $AWS_PROFILE -- kubectl get pods -n datadog-linux

# Check Windows namespace
aws-vault exec $AWS_PROFILE -- kubectl get pods -n datadog-windows

# Verify CRDs (should be in Linux namespace only)
aws-vault exec $AWS_PROFILE -- kubectl get crd | grep datadog

# Verify services
aws-vault exec $AWS_PROFILE -- kubectl get svc -n datadog-linux
```

## Test Commands

### Verify Cluster Agent (Linux)

```bash
# Check Cluster Agent pod
aws-vault exec $AWS_PROFILE -- kubectl get pods -n datadog-linux -l app=datadog-cluster-agent

# View logs
aws-vault exec $AWS_PROFILE -- kubectl logs -n datadog-linux -l app=datadog-cluster-agent -f

# Check agent status
aws-vault exec $AWS_PROFILE -- kubectl exec -n datadog-linux -l app=datadog-cluster-agent -- agent status
```

### Verify Windows Agent

```bash
# Check Windows Agent pods
aws-vault exec $AWS_PROFILE -- kubectl get pods -n datadog-windows

# View logs
aws-vault exec $AWS_PROFILE -- kubectl logs -n datadog-windows -f

# Verify cross-namespace connectivity
aws-vault exec $AWS_PROFILE -- kubectl exec -n datadog-windows <pod-name> -- \
  powershell -c "Invoke-WebRequest http://datadog-linux-cluster-agent.datadog-linux:5005/api/v1/status"
```

### Verify CRD Ownership (No Conflicts)

```bash
# Check CRD ownership metadata
aws-vault exec $AWS_PROFILE -- kubectl get crd datadogdashboards.datadoghq.com -o yaml | grep "meta.helm.sh"

# Expected output should show:
# meta.helm.sh/release-name: datadog-linux
# meta.helm.sh/release-namespace: datadog-linux
```

## Expected Behavior

| Component | Expected Status | Notes |
|-----------|-----------------|-------|
| Linux Cluster Agent | ✅ Running (1/1) | Owns CRDs, manages both platforms |
| Linux Agent DaemonSet | ✅ Running | Deployed to Linux node(s) |
| Windows Agent DaemonSet | ✅ Running | Deployed to Windows node(s) |
| CRD Ownership | ✅ datadog-linux only | No conflicts, single deployment |
| Cross-namespace DNS | ✅ Accessible | `datadog-linux-cluster-agent.datadog-linux:5005` |
| Network Policy | ✅ Allowed by default | Adjust if using Network Policies |

## Troubleshooting

### Cluster Creation Issues

```bash
# Check EKS cluster status
aws-vault exec $AWS_PROFILE -- aws eks describe-cluster \
  --name dd-mixed-cluster-repro \
  --region us-east-1

# Check node group status
aws-vault exec $AWS_PROFILE -- aws eks list-nodegroups \
  --cluster-name dd-mixed-cluster-repro \
  --region us-east-1
```

### Pod Issues

```bash
# Get pod details
aws-vault exec $AWS_PROFILE -- kubectl describe pod <pod-name> -n datadog-linux

# Check events
aws-vault exec $AWS_PROFILE -- kubectl get events -n datadog-linux --sort-by='.lastTimestamp'

# View pod logs
aws-vault exec $AWS_PROFILE -- kubectl logs <pod-name> -n datadog-linux
```

### CRD Conflict Diagnosis

```bash
# Check which release owns each CRD
aws-vault exec $AWS_PROFILE -- kubectl get crd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}{end}' | grep datadog

# If conflict exists, check both releases
aws-vault exec $AWS_PROFILE -- helm list -A | grep datadog
```

## Cleanup

```bash
# Delete Helm releases
aws-vault exec $AWS_PROFILE -- helm uninstall datadog-windows -n datadog-windows
aws-vault exec $AWS_PROFILE -- helm uninstall datadog-linux -n datadog-linux

# Delete namespaces
aws-vault exec $AWS_PROFILE -- kubectl delete namespace datadog-linux
aws-vault exec $AWS_PROFILE -- kubectl delete namespace datadog-windows

# Delete EKS cluster (⚠️ WARNING: This will delete all resources)
aws-vault exec $AWS_PROFILE -- eksctl delete cluster \
  --name dd-mixed-cluster-repro \
  --region us-east-1

# After cluster deletion, verify:
aws-vault exec $AWS_PROFILE -- aws eks list-clusters --region us-east-1
```

## Cost Estimation

| Resource | Type | Hourly Cost |
|----------|------|------------|
| Linux Node (t3.medium) | On-demand | ~$0.0416 |
| Windows Node (t3.large) | On-demand | ~$0.1248 |
| EKS Cluster | Management | $0.10 |
| Data Transfer | Egress | Variable |
| **Total (approx.)** | **Hourly** | **~$0.27/hour** |

**Note:** Costs vary by region. Use AWS Pricing Calculator for exact estimates.

## References

* [AWS EKS Documentation](https://docs.aws.amazon.com/eks/)
* [EKS Mixed Cluster Setup](https://docs.aws.amazon.com/eks/latest/userguide/mixed-node-types.html)
* [Datadog EKS Integration](https://docs.datadoghq.com/containers/kubernetes/installation/)
* [Datadog Windows Containers](https://docs.datadoghq.com/agent/troubleshooting/windows_containers/)
* [AWS Vault Documentation](https://github.com/99designs/aws-vault)
* [eksctl Documentation](https://eksctl.io/)

## Notes

- **AWS Vault Required:** This sandbox uses AWS Vault for credential management. Ensure it's configured with your AWS account access.
- **AWS Profile:** Use `sso-tse-sandbox-account-admin` (verified working profile)
- **Region Configuration:** Commands default to `us-east-1`. Change `--region` parameter for other regions.
- **Cost Awareness:** EKS charges per cluster + EC2 instance costs. Delete cluster when not in use.
- **Windows Node Wait Time:** Windows nodes take significantly longer to provision (~10+ minutes).
- **Cross-Namespace Connectivity:** Assumes default network policies allow inter-namespace communication.
