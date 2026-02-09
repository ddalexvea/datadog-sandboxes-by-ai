# Log Processing Rules Sandbox

A Kubernetes sandbox environment to test Datadog log processing rules with annotation-based configuration.

## Purpose

This sandbox validates that `exclude_at_match` log processing rules correctly filter out INFO and DEBUG level logs while allowing WARN and ERROR logs to pass through to Datadog.

## Log Processing Rule Configuration

The following annotation is applied to the pod:

```yaml
ad.datadoghq.com/log-generator.logs: |
  [{
    "source": "test",
    "service": "test",
    "log_processing_rules": [{
      "type": "exclude_at_match",
      "name": "exclude_info_debug",
      "pattern": "\\b(INFO|info|DEBUG|debug|lvl=info|lvl=debug|level=info|level=debug)\\b"
    }]
  }]
```

### Pattern Breakdown

| Pattern Component | Matches |
|-------------------|---------|
| `\b` | Word boundary |
| `INFO` | Java-style INFO level |
| `info` | Lowercase info level |
| `DEBUG` | Java-style DEBUG level |
| `debug` | Lowercase debug level |
| `lvl=info` | JSON format with lvl key |
| `lvl=debug` | JSON format with lvl key |
| `level=info` | JSON format with level key |
| `level=debug` | JSON format with level key |

## Expected Results

| Log Level | Generated | Visible in Datadog | Status |
|-----------|-----------|-------------------|--------|
| INFO | ✅ | ❌ | Filtered by rule |
| DEBUG | ✅ | ❌ | Filtered by rule |
| WARN | ✅ | ✅ | Passes through |
| ERROR | ✅ | ✅ | Passes through |

## Prerequisites

- Kubernetes cluster (e.g., Minikube)
- Helm installed
- Datadog API key

## Datadog Agent Deployment

### 1. Add the Datadog Helm repository

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update
```

### 2. Create a secret with your API key

```bash
kubectl create secret generic datadog-secret --from-literal=api-key=<YOUR_API_KEY>
```

### 3. Create the Helm values file

Save the following as `datadog-values.yaml`:

```yaml
datadog:
  apiKeyExistingSecret: datadog-secret
  clusterName: minikube
  site: datadoghq.com
  kubelet:
    tlsVerify: false
  logs:
    enabled: true
    containerCollectAll: false
```

### 4. Install the Datadog Agent

```bash
helm install datadog-agent datadog/datadog -f datadog-values.yaml
```

### 5. Verify the Agent is running

```bash
kubectl get pods -l app=datadog-agent
```

### 6. Verify Logs Agent is enabled

```bash
AGENT_POD=$(kubectl get pods -l app=datadog-agent -o jsonpath='{.items[0].metadata.name}')
kubectl exec $AGENT_POD -c agent -- agent status | grep -A 10 "Logs Agent"
```

You should see `Logs Agent is running` in the output.

## Kubernetes Manifest

Save the following as `log-sandbox.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: log-sandbox
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: sample-logs
  namespace: log-sandbox
data:
  # Timestamps are omitted - Datadog will add its own timestamp at ingestion
  logs.txt: |
    INFO  com.pss.ecs.controller.VehicleController - get vehicle device details for editing:261229
    DEBUG com.pss.ecs.serviceimpl.VehicleServiceImpl - device edit get data service:261229
    INFO  com.pss.ecs.daoimpl.VehicleDAOImpl - device edit dao: 261229
    DEBUG com.pss.ecs.serviceimpl.WebsiteServiceImpl - webuser login Insert service
    INFO  com.pss.ecs.daoimpl.WebsiteDAOImpl - web login insert
    INFO  com.pss.ecs.controller.DeviceOrderController - strvehicleId: 292419
    DEBUG com.pss.ecs.daoimpl.NotificationDAOImpl - logCategoryId 3
    WARN  org.apache.fop.apps.FOUserAgent - The following feature isn't implemented by Apache FOP, yet: table-layout="auto"
    WARN  org.apache.fop.apps.FOUserAgent - Font "Symbol,normal,700" not found. Substituting with "Symbol,normal,400".
    WARN  org.apache.fop.apps.FOUserAgent - Font "Tahoma,normal,400" not found. Substituting with "any,normal,400".
    ERROR com.pss.ecs.controller.VehicleController - Failed to process vehicle request: NullPointerException
    ERROR com.pss.ecs.daoimpl.VehicleDAOImpl - Database connection timeout after 30000ms
    INFO  com.pss.ecs.controller.AccountController - Account dashboard
    DEBUG com.pss.ecs.daoimpl.NotificationDAOImpl - logCategoryId 0
    WARN  com.pss.ecs.serviceimpl.PaymentService - Payment retry attempt 2 of 3
    ERROR com.pss.ecs.serviceimpl.PaymentService - Payment failed: Insufficient funds
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-generator
  namespace: log-sandbox
  labels:
    app: log-generator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: log-generator
  template:
    metadata:
      labels:
        app: log-generator
      annotations:
        ad.datadoghq.com/log-generator.logs: |
          [{
            "source": "test",
            "service": "test",
            "log_processing_rules": [{
              "type": "exclude_at_match",
              "name": "exclude_info_debug",
              "pattern": "\\b(INFO|info|DEBUG|debug|lvl=info|lvl=debug|level=info|level=debug)\\b"
            }]
          }]
    spec:
      containers:
      - name: log-generator
        image: busybox:latest
        command:
          - /bin/sh
          - -c
          - |
            while true; do
              while IFS= read -r line; do
                echo "$line"
                sleep 0.5
              done < /logs/logs.txt
              sleep 10
            done
        volumeMounts:
        - name: logs
          mountPath: /logs
      volumes:
      - name: logs
        configMap:
          name: sample-logs
```

## Deployment

### Deploy the sandbox

```bash
kubectl apply -f log-sandbox.yaml
```

### Verify the pod is running

```bash
kubectl get pods -n log-sandbox
```

### View raw logs (before filtering)

```bash
kubectl logs -n log-sandbox deployment/log-generator -f
```

### Check the annotation on the pod

```bash
kubectl get pods -n log-sandbox -o jsonpath='{.items[0].metadata.annotations}' | jq .
```

### Verify Datadog Agent is collecting logs

```bash
# Find the agent pod
AGENT_POD=$(kubectl get pods -l app=datadog-agent -o jsonpath='{.items[0].metadata.name}')

# Check agent status
kubectl exec $AGENT_POD -c agent -- agent status | grep -A 20 "Logs Agent"

# Stream logs being sent to Datadog
kubectl exec $AGENT_POD -c agent -- agent stream-logs --service test
```

## Validation in Datadog

1. Go to **Logs > Live Tail** in the Datadog UI
2. Filter by `service:test`
3. You should only see **WARN** and **ERROR** logs
4. INFO and DEBUG logs should NOT appear

### Expected Behavior (without Log Pipeline)

![Logs Explorer Screenshot](https://github.com/ddalexvea/datadog-agent-log-exclude-at-match-sandbox/blob/main/logs-explorer.png?raw=true)

**Note:** Without a Log Pipeline configured, all logs will appear with `info` status (blue indicator) in the Datadog UI, even though the message content shows `ERROR` or `WARN`. This is because:

- The `exclude_at_match` filter works on the **raw log content** (correctly filtering out INFO/DEBUG)
- The Datadog UI status indicator requires a **Log Pipeline** with a Grok Parser + Status Remapper to extract and display the correct log level

To configure a Log Pipeline with proper status extraction, see the [Datadog Log Pipeline documentation](https://docs.datadoghq.com/developers/integrations/log_pipeline/).

The filtering is working correctly - you will only see logs containing `ERROR` and `WARN` in the message, while `INFO` and `DEBUG` logs are excluded at the Agent level.

## Cleanup

```bash
# Delete the log sandbox
kubectl delete namespace log-sandbox

# Uninstall the Datadog Agent
helm uninstall datadog-agent

# Delete the API key secret
kubectl delete secret datadog-secret
```

## Troubleshooting

### No logs appearing in Datadog

1. Check if the agent discovered the pod:
   ```bash
   kubectl exec $AGENT_POD -c agent -- agent status | grep -A 5 "log-sandbox"
   ```

2. Check agent configcheck for the logs config:
   ```bash
   kubectl exec $AGENT_POD -c agent -- agent configcheck | grep -A 10 "log-generator"
   ```

## References

- [Datadog Agent Log Collection - Advanced Configuration](https://docs.datadoghq.com/agent/logs/advanced_log_collection/)
- [Datadog Log Pipeline documentation](https://docs.datadoghq.com/developers/integrations/log_pipeline/)
- [Regex101 - Test your regex patterns](https://regex101.com/)
