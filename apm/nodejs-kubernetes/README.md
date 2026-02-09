# Datadog APM on Kubernetes Sandbox

This sandbox demonstrates setting up Datadog APM (Application Performance Monitoring) on a Kubernetes cluster with traces and spans collection.

## Overview

This guide covers:
- Setting up Datadog Agent with APM enabled
- Deploying a Node.js application with APM instrumentation
- Verifying traces and spans are being collected
- Troubleshooting APM configuration

## Prerequisites

✅ Minikube running  
✅ Datadog API Key  
✅ Helm 3.x installed  
✅ kubectl configured  

## Current Environment

- **Cluster Name:** tata
- **Namespace:** datadog
- **Datadog Agent Version:** 7.71.2
- **APM Port:** 8126

## Step 1: Verify Current Datadog Configuration

Your current Datadog setup already has APM enabled:

```bash
# Check Datadog pods
kubectl get pods -n datadog

# Verify APM is enabled
kubectl exec -n datadog deployment/datadog-agent-cluster-agent -- agent status | grep -A 10 "APM Agent"
```

## Step 2: APM Configuration (Already Applied)

Your current `datadog-values.yaml` has APM enabled:

```yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "tata"
  
  kubelet:
    tlsVerify: false
  
  # APM Configuration
  apm:
    enabled: true
    portEnabled: true
    port: 8126
  
  # Logs collection
  logs:
    enabled: true
    containerCollectAll: true

clusterAgent:
  enabled: true
  
  admissionController:
    enabled: true
    mutateUnlabelled: false

agents:
  apm:
    enabled: true
    port: 8126
```

## Step 3: Deploy Node.js Application with APM

### Application with dd-trace Instrumentation

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-apm-demo
  namespace: default
  labels:
    app: nodejs-apm-demo
    tags.datadoghq.com/env: "dev"
    tags.datadoghq.com/service: "nodejs-demo-app"
    tags.datadoghq.com/version: "1.0.0"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nodejs-apm-demo
  template:
    metadata:
      labels:
        app: nodejs-apm-demo
        tags.datadoghq.com/env: "dev"
        tags.datadoghq.com/service: "nodejs-demo-app"
        tags.datadoghq.com/version: "1.0.0"
      annotations:
        ad.datadoghq.com/nodejs-apm-demo.logs: '[{"source":"nodejs","service":"nodejs-demo-app"}]'
    spec:
      containers:
      - name: nodejs-apm-demo
        image: nodejs-apm-demo:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 3000
          name: http
        env:
        # Datadog APM configuration
        - name: DD_AGENT_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
        - name: DD_TRACE_AGENT_PORT
          value: "8126"
        - name: DD_ENV
          valueFrom:
            fieldRef:
              fieldPath: metadata.labels['tags.datadoghq.com/env']
        - name: DD_SERVICE
          valueFrom:
            fieldRef:
              fieldPath: metadata.labels['tags.datadoghq.com/service']
        - name: DD_VERSION
          valueFrom:
            fieldRef:
              fieldPath: metadata.labels['tags.datadoghq.com/version']
        - name: DD_LOGS_INJECTION
          value: "true"
        - name: DD_TRACE_SAMPLE_RATE
          value: "1"
        - name: DD_RUNTIME_METRICS_ENABLED
          value: "true"
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: nodejs-apm-demo
  namespace: default
spec:
  selector:
    app: nodejs-apm-demo
  ports:
  - protocol: TCP
    port: 80
    targetPort: 3000
  type: NodePort
```

### Deploy the Application

```bash
# Application is already deployed
kubectl get deployment nodejs-apm-demo -n default

# Check if running
kubectl get pods -l app=nodejs-apm-demo
```

## Step 4: Generate Traffic and Traces

### Generate Simple Traces

```bash
# Generate traffic to the root endpoint
kubectl run curl-test --image=curlimages/curl --restart=Never -- \
  sh -c "for i in 1 2 3 4 5; do curl -s http://nodejs-apm-demo/; sleep 1; done"

# Generate traffic to complex endpoint with custom spans
kubectl run curl-api --image=curlimages/curl --restart=Never -- \
  sh -c "for i in 1 2 3 4 5; do curl -s http://nodejs-apm-demo/api/users; sleep 1; done"

# Generate an error trace
kubectl run curl-error --image=curlimages/curl --restart=Never -- \
  sh -c "curl -s http://nodejs-apm-demo/api/error"
```

### Check Application Logs

```bash
kubectl logs -l app=nodejs-apm-demo --tail=20
```

## Step 5: Verify APM Agent is Receiving Traces

### Check Trace Agent Status

```bash
kubectl exec -n datadog daemonset/datadog-agent -c trace-agent -- agent status
```

Look for the **APM Agent** section showing traces received:

```
APM Agent
=========
  Status: Running
  Receiver: 0.0.0.0:8126
  
  Receiver (previous minute)
  ==========================
    From nodejs v18.20.8 (v8), client 5.73.0
      Traces received: 28 (55,407 bytes)
      Spans received: 98
  
  Writer (previous minute)
  ========================
    Traces: 1 payloads, 0 traces, 0 events, 2,771 bytes
    Stats: 1 payloads, 1 stats buckets, 1,097 bytes
```

### Quick APM Check

```bash
# Get the agent pod name
AGENT_POD=$(kubectl get pods -n datadog -l app=datadog-agent -o jsonpath='{.items[0].metadata.name}')

# Check APM status
kubectl exec -n datadog $AGENT_POD -c trace-agent -- agent status 2>/dev/null | grep -A 15 "APM Agent"
```

## Step 6: View Traces in Datadog UI

Go to: **https://app.datadoghq.com/apm/traces**

### Filter by:
- **Service:** `nodejs-demo-app`
- **Environment:** `dev`
- **Cluster:** `tata`

### What You'll See:
- Request traces with operation names like `express.request`
- Custom spans like `database.query` and `external.api.call`
- Error traces from the `/api/error` endpoint
- Latency breakdowns showing where time is spent
- Service map showing dependencies
- Runtime metrics (CPU, memory)

## Application Endpoints

The demo application has the following endpoints:

- `GET /` - Simple endpoint (basic trace)
- `GET /api/users` - Complex endpoint with custom database and external API spans
- `GET /api/error` - Error tracking endpoint (generates errors for APM)
- `GET /health` - Health check endpoint

## Understanding the Traces

### Simple Trace (GET /)
- Single span showing HTTP request handling
- Response time
- Status code

### Complex Trace (GET /api/users)
- Parent span: `express.request`
- Child span 1: `database.query` (simulated DB call)
- Child span 2: `external.api.call` (simulated external API)
- Total latency breakdown across all spans

### Error Trace (GET /api/error)
- Trace marked as error
- Exception details
- Stack trace
- Error message

## Troubleshooting Guide

### Issue 1: No traces appearing in Datadog

**Check 1: Verify APM Agent is running**
```bash
kubectl exec -n datadog daemonset/datadog-agent -c trace-agent -- agent status | grep "Status:"
```

Expected: `Status: Running`

**Check 2: Verify application is sending traces**
```bash
kubectl logs -l app=nodejs-apm-demo | grep -i "datadog\|trace\|agent"
```

**Check 3: Verify DD_AGENT_HOST is set correctly**
```bash
kubectl get pod -l app=nodejs-apm-demo -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="DD_AGENT_HOST")].valueFrom.fieldRef.fieldPath}'
```

Expected: `status.hostIP`

### Issue 2: Traces received but not in Datadog UI

**Check 1: API Key is valid**
```bash
kubectl logs -n datadog daemonset/datadog-agent -c trace-agent | grep -i "api key"
```

**Check 2: Traces are being forwarded**
```bash
kubectl exec -n datadog daemonset/datadog-agent -c trace-agent -- agent status | grep -A 5 "Writer"
```

### Issue 3: Application not connecting to trace agent

**Check 1: Port 8126 is accessible**
```bash
kubectl get pods -l app=nodejs-apm-demo -o yaml | grep -A 5 "DD_TRACE_AGENT_PORT"
```

**Check 2: Test connectivity**
```bash
POD=$(kubectl get pod -l app=nodejs-apm-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- nc -zv $DD_AGENT_HOST 8126
```

## Useful Commands

### Check all APM-related pods
```bash
kubectl get pods -n datadog -o wide
kubectl get pods -l app=nodejs-apm-demo -o wide
```

### View trace agent logs
```bash
kubectl logs -n datadog daemonset/datadog-agent -c trace-agent --tail=50 -f
```

### View application logs
```bash
kubectl logs -l app=nodejs-apm-demo -f
```

### Generate continuous traffic
```bash
kubectl run load-generator --image=busybox --restart=Never -- \
  sh -c "while true; do wget -q -O- http://nodejs-apm-demo/api/users; sleep 2; done"
```

### Clean up test pods
```bash
kubectl delete pod curl-test curl-api curl-error load-generator 2>/dev/null || true
```

## APM Configuration Best Practices

### ✅ DO:

- Set unified service tagging (service, env, version)
- Enable logs injection (`DD_LOGS_INJECTION: "true"`)
- Use appropriate sample rates (start with 1 for testing)
- Enable runtime metrics for language-level insights
- Use meaningful service names
- Tag resources consistently

### ❌ DON'T:

- Hardcode the agent host (use `status.hostIP`)
- Sample at 100% in production (can be expensive)
- Forget to set DD_ENV and DD_SERVICE
- Mix different service names for the same application
- Skip resource requests/limits

## Verification Checklist

- [ ] Datadog Agent pods running
- [ ] APM enabled in Helm values
- [ ] Trace agent listening on port 8126
- [ ] Application has dd-trace library installed
- [ ] DD_AGENT_HOST environment variable set
- [ ] DD_TRACE_AGENT_PORT set to 8126
- [ ] Unified service tags configured
- [ ] Traffic generated to application
- [ ] Traces visible in `agent status` output
- [ ] Traces forwarded to Datadog
- [ ] Traces visible in Datadog APM UI

## Clean Up

```bash
# Remove test application
kubectl delete deployment nodejs-apm-demo -n default
kubectl delete service nodejs-apm-demo -n default

# Remove test pods
kubectl delete pod curl-test curl-api curl-error 2>/dev/null || true
```

## Additional Resources

- [Datadog APM Documentation](https://docs.datadoghq.com/tracing/)
- [Node.js APM Setup](https://docs.datadoghq.com/tracing/setup_overview/setup/nodejs/)
- [dd-trace-js GitHub](https://github.com/DataDog/dd-trace-js)
- [Custom Instrumentation](https://docs.datadoghq.com/tracing/trace_collection/custom_instrumentation/nodejs/)
- [Unified Service Tagging](https://docs.datadoghq.com/getting_started/tagging/unified_service_tagging/)

## Sandbox Information

**Created by:** Alexandre VEA  
**Last Updated:** October 24, 2025  
**Cluster:** tata (minikube)  
**Datadog Agent Version:** 7.71.2  
**APM Agent Status:** ✅ Running and receiving traces
