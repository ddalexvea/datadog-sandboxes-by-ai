# Datadog HPA Events Integration Setup on Kubernetes

This guide walks through installing Datadog on a Kubernetes cluster with HPA (Horizontal Pod Autoscaler) event collection enabled using unbundled events and custom filtering.

## Prerequisites

* Kubernetes cluster running (minikube, EKS, GKE, AKS, etc.)
* helm 3.x installed
* kubectl configured
* metrics-server installed (required for HPA to function)

## Step 1: Add Datadog Helm Repository

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update
```

## Step 2: Create Datadog API Key Secret

```bash
kubectl create secret generic datadog-secret --from-literal api-key=YOUR_API_KEY
```

Replace `YOUR_API_KEY` with your actual Datadog API key.

## Step 3: Create Datadog Values File

Create a file named `datadog-values.yaml` with the following configuration:

```yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "my-cluster"
  
  # Kubernetes event collection configuration
  kubernetesEvents:
    sourceDetectionEnabled: true
    unbundleEvents: true
    collectedEventTypes:
      - kind: Pod
        reasons:
          - Failed
          - BackOff
          - Unhealthy
          - FailedScheduling
          - FailedMount
          - FailedAttachVolume
      - kind: Node
        reasons:
          - TerminatingEvictedPod
          - NodeNotReady
          - Rebooted
          - HostPortConflict
      - kind: CronJob
        reasons:
          - SawCompletedJob
      - kind: HorizontalPodAutoscaler
        reasons:
          - SuccessfulRescale
          - FailedGetResourceMetric
          - FailedComputeMetricsReplicas
          - FailedGetExternalMetric
          - FailedGetObjectMetric
          - FailedGetPodsMetric
  
  # Cluster Agent configuration (required for event collection)
  clusterAgent:
    enabled: true
    replicas: 1
```

### Configuration Breakdown:

* **`site`**: Your Datadog site (e.g., `datadoghq.com`, `datadoghq.eu`)
* **`apiKeyExistingSecret`**: Reference to the Kubernetes secret containing the API key
* **`clusterName`**: Identifier for your cluster in Datadog
* **`kubernetesEvents.sourceDetectionEnabled`**: Automatically detects event sources based on controller names (Requires Cluster Agent 7.56.0+)
* **`kubernetesEvents.unbundleEvents`**: Enables 1:1 mapping between Kubernetes and Datadog events (Requires Cluster Agent 7.42.0+)
* **`kubernetesEvents.collectedEventTypes`**: Custom whitelist of Kubernetes events to collect
* **`clusterAgent.enabled`**: Required for Kubernetes event collection

## Step 4: Install Datadog Agent

```bash
helm install datadog-agent -f datadog-values.yaml datadog/datadog
```

## Step 5: Verify Installation

Check that all Datadog pods are running:

```bash
kubectl get pods -l app.kubernetes.io/instance=datadog-agent
```

Expected output:

```
NAME                                           READY   STATUS    RESTARTS   AGE
datadog-agent-6mjww                            2/2     Running   0          2m
datadog-agent-cluster-agent-7b7bc7b476-n492z   1/1     Running   0          2m
```

## Step 6: Verify Event Collection Configuration

Check that event collection is enabled:

```bash
kubectl exec $(kubectl get pod -l app.kubernetes.io/component=cluster-agent -o name) -- agent config | grep -i "collect_kubernetes_events"
```

Expected output:

```
collect_kubernetes_events: true
```

## Step 7: Verify HPA Event Configuration

Check that HPA events are in the collected event types:

```bash
kubectl exec $(kubectl get pod -l app.kubernetes.io/component=cluster-agent -o name) -- agent configcheck | grep -A 30 "collected_event_types"
```

Expected output should include:

```yaml
- kind: HorizontalPodAutoscaler
  reasons:
    - SuccessfulRescale
    - FailedGetResourceMetric
    - FailedComputeMetricsReplicas
```

## Step 8: Install Metrics Server (If Not Already Installed)

HPA requires metrics-server to collect CPU and memory metrics:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

For **minikube**, patch metrics-server to allow insecure TLS:

```bash
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
```

Verify metrics-server is running:

```bash
kubectl get deployment metrics-server -n kube-system
```

## Step 9: Create Test HPA Setup

Create a test application and HPA configuration:

```yaml
# hpa-test-setup.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: php-apache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: php-apache
  template:
    metadata:
      labels:
        app: php-apache
    spec:
      containers:
      - name: php-apache
        image: registry.k8s.io/hpa-example
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 200m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: php-apache
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: php-apache
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: php-apache-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: php-apache
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
```

Apply the test setup:

```bash
kubectl apply -f hpa-test-setup.yaml
```

## Step 10: Monitor HPA Status

Check HPA is working:

```bash
kubectl get hpa php-apache-hpa
```

Expected output (after metrics-server collects data):

```
NAME             REFERENCE               TARGETS    MINPODS   MAXPODS   REPLICAS   AGE
php-apache-hpa   Deployment/php-apache   0%/50%     2         10        2          1m
```

## Step 11: Generate Load to Trigger Scaling

Create a load generator to trigger HPA scaling:

```yaml
# load-generator.yaml
apiVersion: v1
kind: Pod
metadata:
  name: load-generator
spec:
  containers:
  - name: load-generator
    image: busybox
    command: ["/bin/sh"]
    args:
    - -c
    - |
      while true; do
        wget -q -O- http://php-apache.default.svc.cluster.local
      done
  restartPolicy: Always
```

Apply the load generator:

```bash
kubectl apply -f load-generator.yaml
```

## Step 12: Watch HPA Scaling Events

Monitor HPA events:

```bash
kubectl get events --field-selector involvedObject.kind=HorizontalPodAutoscaler --watch
```

You should see events like:

```
LAST SEEN   TYPE     REASON              MESSAGE
30s         Normal   SuccessfulRescale   New size: 5; reason: cpu resource utilization above target
```

## Step 13: Verify Events in Datadog Cluster Agent

Check that events are being collected:

```bash
kubectl exec $(kubectl get pod -l app.kubernetes.io/component=cluster-agent -o name) -- agent status 2>&1 | grep -A 5 "Events Flushed"
```

Expected output:

```
Events Flushed: 10
```

## Step 14: View Events in Datadog

HPA events will be visible in the Datadog Event Explorer:

* URL: https://app.datadoghq.com/event/explorer
* Search for: `source:kubernetes kube_kind:horizontalpodautoscaler`

Events should include tags such as:

* `kube_cluster_name:my-cluster`
* `kube_namespace:default`
* `kube_kind:HorizontalPodAutoscaler`
* `kube_horizontal_pod_autoscaler:php-apache-hpa`
* `reason:SuccessfulRescale` or `reason:FailedGetResourceMetric`

### Example Event Structure:

```json
{
  "title": "HorizontalPodAutoscaler default/php-apache-hpa: SuccessfulRescale",
  "text": "New size: 5; reason: cpu resource utilization above target",
  "status": "info",
  "tags": [
    "kube_cluster_name:my-cluster",
    "kube_namespace:default",
    "kube_horizontal_pod_autoscaler:php-apache-hpa",
    "reason:SuccessfulRescale"
  ]
}
```

## Step 15: Test Scale-Down Events

Stop the load generator to trigger scale-down:

```bash
kubectl delete pod load-generator
```

Wait for HPA to scale down (this may take a few minutes due to stabilization windows):

```bash
kubectl get hpa php-apache-hpa --watch
```

You should see scale-down events in Datadog Event Explorer.

## Step 16: Clean Up Test Resources

```bash
kubectl delete -f hpa-test-setup.yaml
kubectl delete pod load-generator
```

## Updating Datadog Configuration

If you need to update the Datadog configuration later:

```bash
helm upgrade datadog-agent -f datadog-values.yaml datadog/datadog
```

## Troubleshooting

### Issue: HPA shows "unknown" for CPU/memory metrics

**Symptoms:**
```
TARGETS: cpu: <unknown>/50%
```

**Solution:** Install or verify metrics-server is running:
```bash
kubectl get deployment metrics-server -n kube-system
kubectl top nodes  # Should show resource usage
```

### Issue: HPA events not appearing in Datadog

**Solution 1:** Verify HPA is in `collectedEventTypes`:
```bash
kubectl exec $(kubectl get pod -l app.kubernetes.io/component=cluster-agent -o name) -- agent configcheck | grep -A 20 "collected_event_types"
```

**Solution 2:** Check that events are being generated in Kubernetes:
```bash
kubectl get events --field-selector involvedObject.kind=HorizontalPodAutoscaler
```

### Issue: Too many HPA events

**Solution:** Adjust HPA event reasons to be more selective:
```yaml
- kind: HorizontalPodAutoscaler
  reasons:
    - SuccessfulRescale  # Only collect successful scaling events
```

### Issue: Events have wrong cluster name

**Solution:** Set `clusterName` in values.yaml:
```yaml
datadog:
  clusterName: "your-actual-cluster-name"
```

## Advanced Configuration

### Collect All HPA Events (No Reason Filtering)

To collect ALL HPA events regardless of reason:

```yaml
- kind: HorizontalPodAutoscaler
  # No reasons specified = collect all reasons
```

### Add Custom Kubernetes Resource Events

To monitor other Kubernetes resources:

```yaml
collectedEventTypes:
  - kind: Deployment
    reasons:
      - ScalingReplicaSet
  - kind: StatefulSet
    reasons:
      - SuccessfulCreate
      - FailedCreate
```

### Enable Datadog's Pre-Defined Event Filter

Instead of custom `collectedEventTypes`, use Datadog's curated list:

```yaml
kubernetesEvents:
  sourceDetectionEnabled: true
  unbundleEvents: true
  filteringEnabled: true  # Use Datadog's pre-defined filter
  # Remove collectedEventTypes
```

## Key Configuration Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `kubernetesEvents.sourceDetectionEnabled` | `true` | Automatically detects event sources |
| `kubernetesEvents.unbundleEvents` | `true` | Enables 1:1 event mapping |
| `kubernetesEvents.filteringEnabled` | `false` | Disables Datadog's pre-defined filter |
| `kubernetesEvents.collectedEventTypes` | Custom list | Your whitelist of events to collect |
| `clusterAgent.enabled` | `true` | Required for event collection |

## HPA Event Reasons Reference

| Reason | Type | Description |
|--------|------|-------------|
| `SuccessfulRescale` | Normal | HPA successfully scaled the deployment |
| `FailedGetResourceMetric` | Warning | Unable to get CPU/memory metrics |
| `FailedComputeMetricsReplicas` | Warning | Unable to calculate desired replicas |
| `FailedGetExternalMetric` | Warning | Unable to get external metrics |
| `FailedGetObjectMetric` | Warning | Unable to get object metrics |
| `FailedGetPodsMetric` | Warning | Unable to get pod metrics |

## Best Practices

1. **Start with specific reasons**: Only collect HPA events you need to avoid noise
2. **Monitor event volume**: Check Datadog Event Explorer regularly for event volume
3. **Use source detection**: Enable `sourceDetectionEnabled` for better event attribution
4. **Set appropriate HPA thresholds**: Configure HPA stabilization windows to reduce flapping
5. **Create monitors**: Set up Datadog monitors for HPA scaling failures
6. **Tag your HPAs**: Use labels on HPAs for better filtering in Datadog

## References

* [Datadog Kubernetes Event Collection Documentation](https://docs.datadoghq.com/containers/kubernetes/event_collection/)
* [Datadog Helm Chart Repository](https://github.com/DataDog/helm-charts)
* [Kubernetes HPA Documentation](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
* [Kubernetes Metrics Server](https://github.com/kubernetes-sigs/metrics-server)

## About

This guide demonstrates how to configure Datadog to collect Kubernetes HPA (Horizontal Pod Autoscaler) events using unbundled events and custom filtering. By default, HPA events are NOT collected by Datadog to reduce noise and cost. This guide shows you how to opt-in to HPA event collection for better visibility into autoscaling behavior.

