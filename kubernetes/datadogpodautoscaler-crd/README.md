# Datadog Kubernetes Autoscaling Setup and Troubleshooting

This guide walks through installing Datadog Kubernetes Autoscaling on a cluster and demonstrates how to troubleshoot the common error: **"Autoscaling target cannot be set to the cluster agent"**.

## Prerequisites

* Kubernetes cluster running (minikube, kind, or any K8s cluster)
* Helm 3.x installed
* kubectl configured
* Datadog account with API and Application keys

## Overview

The DatadogPodAutoscaler (DPA) is a Kubernetes Custom Resource Definition (CRD) that provides intelligent workload autoscaling based on Datadog's recommendations. This guide covers:

* Setting up Datadog with autoscaling enabled
* Understanding the validation error that prevents DPA from targeting the cluster agent
* Troubleshooting and resolving configuration issues

## Step 1: Add Datadog Helm Repository

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update
```

## Step 2: Create Datadog Secrets

Create a namespace for Datadog:

```bash
kubectl create namespace datadog
```

Create secrets with your API and Application keys:

```bash
# API Key (required)
kubectl create secret generic datadog-secret \
  --from-literal api-key=YOUR_API_KEY \
  -n datadog

# Application Key (required for autoscaling)
kubectl create secret generic datadog-app-secret \
  --from-literal app-key=YOUR_APP_KEY \
  -n datadog
```

Replace `YOUR_API_KEY` and `YOUR_APP_KEY` with your actual Datadog keys:
- **API Key**: https://app.datadoghq.com/organization-settings/api-keys
- **Application Key**: https://app.datadoghq.com/organization-settings/application-keys

## Step 3: Create Datadog Values File

Create a file named `datadog-values.yaml` with the following configuration:

```yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  appKeyExistingSecret: "datadog-app-secret"
  clusterName: "my-cluster"
  autoscaling:
    workload:
      enabled: true
  kubernetesEvents:
    unbundleEvents: true

clusterAgent:
  enabled: true
  admissionController:
    enabled: true
  metricsProvider:
    enabled: true
  env:
    - name: DD_AUTOSCALING_FAILOVER_ENABLED
      value: "true"
    - name: DD_REMOTE_CONFIGURATION_ENABLED
      value: "true"

agents:
  enabled: true
  env:
    - name: DD_AUTOSCALING_FAILOVER_ENABLED
      value: "true"
```

### Configuration Breakdown

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `datadog.site` | `datadoghq.com` | Your Datadog site (US1, EU, etc.) |
| `datadog.apiKeyExistingSecret` | `datadog-secret` | Reference to API key secret |
| `datadog.appKeyExistingSecret` | `datadog-app-secret` | Reference to APP key secret (required for autoscaling) |
| `datadog.clusterName` | `my-cluster` | Identifier for your cluster in Datadog |
| `datadog.autoscaling.workload.enabled` | `true` | Enables DatadogPodAutoscaler feature |
| `datadog.kubernetesEvents.unbundleEvents` | `true` | Required for autoscaling |
| `clusterAgent.admissionController.enabled` | `true` | Required for DPA webhook |
| `clusterAgent.metricsProvider.enabled` | `true` | Enables custom metrics API |
| `DD_AUTOSCALING_FAILOVER_ENABLED` | `true` | Enables autoscaling failover |
| `DD_REMOTE_CONFIGURATION_ENABLED` | `true` | Required for autoscaling |

## Step 4: Install Datadog Agent

```bash
helm install datadog datadog/datadog \
  -n datadog \
  -f datadog-values.yaml
```

## Step 5: Verify Installation

Check that all Datadog pods are running:

```bash
kubectl get pods -n datadog
```

Expected output:

```
NAME                                    READY   STATUS    RESTARTS   AGE
datadog-cluster-agent-c8f9c6b48-xxxxx   1/1     Running   0          2m
datadog-xxxxx                           2/2     Running   0          2m
```

Verify CRDs are installed:

```bash
kubectl get crd | grep datadog
```

Expected output:

```
datadogmetrics.datadoghq.com          2025-10-15T09:20:53Z
datadogpodautoscalers.datadoghq.com   2025-10-15T09:20:53Z
```

## Step 6: Verify Autoscaling Components

### Check External Metrics API

```bash
kubectl get apiservice v1beta1.external.metrics.k8s.io
```

Expected status: `Available: True`

### Check Autoscaling in Cluster Agent Logs

```bash
kubectl logs -n datadog deployment/datadog-cluster-agent | grep -i autoscal
```

Expected output should include:

```
INFO | Starting local autoscaling recommender
INFO | Started controller: dpa-c (cache sync finished)
```

### Check for Any Existing DatadogPodAutoscalers

```bash
kubectl get datadogpodautoscaler -A
```

or using the short name:

```bash
kubectl get dpa -A
```

## Step 7: Understanding the Error

### The Validation Error

The Datadog Cluster Agent includes a validation check to prevent a DatadogPodAutoscaler from targeting itself. This error occurs when:

1. The DatadogPodAutoscaler is in the **same namespace** as the Cluster Agent
2. The DatadogPodAutoscaler's `targetRef` points to the **Cluster Agent deployment**

**Complete Error Message:**
```
2025-10-15 08:46:40 UTC | CLUSTER | ERROR | (pkg/clusteragent/autoscaling/workload/controller.go:145 in Process) | 
Impossible to synchronize DatadogPodAutoscaler (attempt #1): datadog/datadog-cluster-agent-autoscaler-a4502a4b, 
err: Autoscaling target cannot be set to the cluster agent
```

**Error Components:**
- **Timestamp:** `2025-10-15 08:46:40 UTC`
- **Level:** `ERROR`
- **Source:** `pkg/clusteragent/autoscaling/workload/controller.go:145`
- **Function:** `Process`
- **Resource:** `datadog/datadog-cluster-agent-autoscaler-a4502a4b`
- **Message:** `Impossible to synchronize DatadogPodAutoscaler (attempt #1)`
- **Root Cause:** `Autoscaling target cannot be set to the cluster agent`

### Why This Validation Exists

This is an **explicit safeguard** to prevent circular dependencies:

- The Cluster Agent **manages** autoscaling decisions
- If it tried to autoscale **itself**, it would create a feedback loop
- The Cluster Agent needs to remain stable to manage other workloads

**Implementation Reference:**

This validation was introduced in the Datadog Agent to prevent misconfiguration. The code check is located in the workload autoscaling controller:

```go
if podAutoscalerInternal.Namespace() == clusterAgentNs && 
   podAutoscalerInternal.Spec().TargetRef.Name == resourceName {
    return fmt.Errorf("Autoscaling target cannot be set to the cluster agent")
}
```

**Source:** [Datadog Agent Commit c4e3a15](https://github.com/DataDog/datadog-agent/commit/c4e3a1565923302d6821e41893e9db17a9877d5a)

## Step 8: Reproducing the Error

Create a misconfigured DatadogPodAutoscaler that targets the cluster agent:

```yaml
# test-bad-autoscaler.yaml
apiVersion: datadoghq.com/v1alpha2
kind: DatadogPodAutoscaler
metadata:
  name: bad-autoscaler-test
  namespace: datadog  # ❌ Same namespace as cluster agent
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: datadog-cluster-agent  # ❌ Targeting cluster agent itself!
  constraints:
    maxReplicas: 10
    minReplicas: 1
  owner: Local
  applyPolicy:
    mode: Apply
  objectives:
    - type: PodResource
      podResource:
        name: cpu
        value:
          type: Utilization
          utilization: 75
```

Apply the misconfigured autoscaler:

```bash
kubectl apply -f test-bad-autoscaler.yaml
```

## Step 9: Verifying the Error

### Method 1: Using kubectl describe (Recommended)

```bash
kubectl describe datadogpodautoscaler bad-autoscaler-test -n datadog
```

Look for the error in the **Status → Conditions** section:

```yaml
Status:
  Conditions:
    Last Transition Time:  2025-10-15T09:24:57Z
    Reason:                Autoscaling target cannot be set to the cluster agent
    Status:                True
    Type:                  Error
```

### Method 2: Quick Status Check

```bash
kubectl get dpa -n datadog -o wide
```

Look for the **IN ERROR** column showing `True`:

```
NAME                  APPLY MODE   ACTIVE   IN ERROR   ABLE TO SCALE
bad-autoscaler-test                True     True       Unknown
```

### Method 3: Cluster Agent Logs

```bash
kubectl logs -n datadog deployment/datadog-cluster-agent | grep "Autoscaling target"
```

Expected output:

```
2025-10-15 09:24:57 UTC | CLUSTER | ERROR | (pkg/clusteragent/autoscaling/workload/controller.go:145 in Process) | 
Impossible to synchronize DatadogPodAutoscaler (attempt #1): datadog/bad-autoscaler-test, 
err: Autoscaling target cannot be set to the cluster agent
```

### Method 4: JSON Query for All Errored Autoscalers

```bash
kubectl get dpa -A -o json | \
  jq -r '.items[] | select(.status.conditions[]? | select(.type=="Error" and .status=="True")) | 
  "\(.metadata.namespace)/\(.metadata.name): \(.status.conditions[] | select(.type=="Error").reason)"'
```

## Step 10: Fixing the Error

### Identify the Problematic Configuration

1. List all DatadogPodAutoscaler resources:

```bash
kubectl get dpa -A
```

2. Describe the problematic autoscaler:

```bash
kubectl describe dpa <DPA_NAME> -n <NAMESPACE>
```

3. Check the `targetRef` section:

```yaml
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: datadog-cluster-agent  # ❌ This is the problem!
```

### Solution: Update or Delete the Autoscaler

**Option 1: Delete the misconfigured autoscaler**

```bash
kubectl delete dpa bad-autoscaler-test -n datadog
```

**Option 2: Edit to target your actual application**

```bash
kubectl edit dpa bad-autoscaler-test -n datadog
```

Change the `targetRef` to point to your application:

```yaml
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: your-application  # ✅ Your app, not datadog-cluster-agent
```

## Step 11: Creating a Correct DatadogPodAutoscaler

Here's how to create a **correct** DatadogPodAutoscaler for your application:

```yaml
# correct-autoscaler.yaml
apiVersion: datadoghq.com/v1alpha2
kind: DatadogPodAutoscaler
metadata:
  name: my-app-autoscaler
  namespace: default  # ✅ Your application's namespace
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-application  # ✅ Your application name
  constraints:
    maxReplicas: 50
    minReplicas: 2
  owner: Local
  applyPolicy:
    mode: Apply  # Use "Preview" to test without actual scaling
  objectives:
    - type: PodResource
      podResource:
        name: cpu
        value:
          type: Utilization
          utilization: 75
```

### Key Points for Correct Configuration:

✅ **DO:**
- Target your application deployments
- Use different namespaces for your apps
- Set appropriate min/max replica constraints
- Use `mode: Preview` for testing

❌ **DON'T:**
- Target Datadog components (cluster-agent, node agents)
- Create DPAs in the `datadog` namespace targeting Datadog workloads
- Set extreme replica limits without testing

Apply the correct autoscaler:

```bash
kubectl apply -f correct-autoscaler.yaml
```

## Step 12: Verify Autoscaler is Working

Check the autoscaler status:

```bash
kubectl get dpa my-app-autoscaler -n default -o wide
```

Expected output (no errors):

```
NAME                APPLY MODE   ACTIVE   IN ERROR   ABLE TO SCALE   DESIRED REPLICAS
my-app-autoscaler   Apply        True     False      True            2
```

Check detailed status:

```bash
kubectl describe dpa my-app-autoscaler -n default
```

Look for healthy conditions:

```yaml
Status:
  Conditions:
    Status:  False
    Type:    Error  # ✅ False means no error
    Status:  True
    Type:    HorizontalAbleToScale  # ✅ Ready to scale
```

## Troubleshooting Guide

### Issue 1: Error "Autoscaling target cannot be set to the cluster agent"

**Symptoms:**
- Error in cluster agent logs
- DPA status shows `IN ERROR: True`
- Status reason: "Autoscaling target cannot be set to the cluster agent"

**Root Cause:**
DatadogPodAutoscaler is targeting the Datadog Cluster Agent itself.

**Solution:**
1. Identify the problematic DPA:
   ```bash
   kubectl get dpa -n datadog
   ```
2. Check its target:
   ```bash
   kubectl describe dpa <DPA_NAME> -n datadog
   ```
3. Delete or update it to target your application instead:
   ```bash
   kubectl delete dpa <DPA_NAME> -n datadog
   ```

### Issue 2: DatadogPodAutoscaler CRD not found

**Symptoms:**
```
error: the server doesn't have a resource type "datadogpodautoscalers"
```

**Root Cause:**
- Autoscaling not enabled in Helm values
- CRDs not installed

**Solution:**
1. Verify autoscaling is enabled in `datadog-values.yaml`:
   ```yaml
   datadog:
     autoscaling:
       workload:
         enabled: true
   ```
2. Reinstall/upgrade Datadog:
   ```bash
   helm upgrade datadog datadog/datadog -n datadog -f datadog-values.yaml
   ```
3. Verify CRD exists:
   ```bash
   kubectl get crd datadogpodautoscalers.datadoghq.com
   ```

## Verification Checklist

Use this checklist to verify your Datadog Kubernetes Autoscaling setup:

- [ ] Datadog Helm repository added
- [ ] Namespace `datadog` created
- [ ] API Key secret created
- [ ] APP Key secret created
- [ ] Helm values file configured with autoscaling enabled
- [ ] Datadog Agent installed via Helm
- [ ] All Datadog pods running (cluster agent + node agents)
- [ ] DatadogPodAutoscaler CRD exists
- [ ] External metrics API service available
- [ ] Admission Controller webhook configured
- [ ] Cluster agent logs show autoscaling controller started
- [ ] Remote Configuration enabled in Datadog org
- [ ] No DatadogPodAutoscalers targeting Datadog components
- [ ] Test application has a valid DatadogPodAutoscaler
- [ ] Autoscaling recommendations visible in Datadog UI

## Clean Up Test Resources

Remove the test autoscaler:

```bash
kubectl delete dpa bad-autoscaler-test -n datadog
rm test-bad-autoscaler.yaml
```

Remove Datadog completely (if needed):

```bash
helm uninstall datadog -n datadog
kubectl delete namespace datadog
```

## Key Takeaways

1. **DatadogPodAutoscaler** is a CRD that enables intelligent autoscaling
2. **Never target Datadog components** (cluster agent, node agents) with a DPA
3. **APP Key is required** for autoscaling functionality
4. **Remote Configuration must be enabled** in your Datadog organization
5. Use **`kubectl describe dpa`** to troubleshoot DPA issues
6. Check **Status → Conditions** for error details
7. Test with **`mode: Preview`** before enabling actual scaling

## Additional Resources

- [Datadog Kubernetes Autoscaling Documentation](https://docs.datadoghq.com/containers/monitoring/autoscaling/)
- [DatadogPodAutoscaler API Reference](https://github.com/DataDog/datadog-operator/blob/main/docs/datadogpodautoscaler.md)

---

**Created by:** Alexandre VEA
**Last Updated:** October 15, 2025  
**Version:** 1.0  
**License:** MIT
