# JMX Integration - Tomcat on Kubernetes

## Overview

This sandbox demonstrates JMX metric collection from a Tomcat application running in Kubernetes using the Datadog Agent with JMXFetch.

**Use Case:** Troubleshooting JMX connectivity issues in Kubernetes environments.

## Prerequisites

- Minikube or Kubernetes cluster
- Helm 3.x
- `kubectl` configured
- Datadog API key

## Setup

### 1. Start Minikube

```bash
minikube start --memory=4096 --cpus=2
minikube status
```

### 2. Create Namespace

```bash
kubectl create namespace sandbox
```

### 3. Deploy Tomcat with JMX Enabled

**⚠️ Critical:** The `java.rmi.server.hostname` must be set to the Pod IP, NOT `0.0.0.0` or `localhost`.

```bash
kubectl apply -n sandbox -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: tomcat-jmx
  labels:
    app: tomcat-jmx
  annotations:
    ad.datadoghq.com/tomcat.checks: |
      {
        "tomcat": {
          "init_config": {},
          "instances": [{"host": "%%host%%", "port": "9012"}]
        }
      }
spec:
  containers:
  - name: tomcat
    image: tomcat:9-jdk11
    ports:
    - containerPort: 8080
      name: http
    - containerPort: 9012
      name: jmx
    env:
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    - name: CATALINA_OPTS
      value: >-
        -Dcom.sun.management.jmxremote=true
        -Dcom.sun.management.jmxremote.port=9012
        -Dcom.sun.management.jmxremote.rmi.port=9012
        -Dcom.sun.management.jmxremote.authenticate=false
        -Dcom.sun.management.jmxremote.ssl=false
        -Dcom.sun.management.jmxremote.local.only=false
        -Djava.rmi.server.hostname=$(POD_IP)
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
EOF
```

### 4. Wait for Pod Ready

```bash
kubectl wait --for=condition=ready pod -n sandbox -l app=tomcat-jmx --timeout=120s
```

### 5. Deploy Datadog Agent

```bash
kubectl create namespace datadog
kubectl create secret generic datadog-secret -n datadog --from-literal=api-key="$DD_API_KEY"

helm repo add datadog https://helm.datadoghq.com && helm repo update

helm upgrade --install datadog-agent datadog/datadog -n datadog \
  --set datadog.apiKeyExistingSecret=datadog-secret \
  --set datadog.site=datadoghq.com \
  --set datadog.clusterName=jmx-sandbox \
  --set datadog.kubelet.tlsVerify=false \
  --set clusterAgent.enabled=true \
  --set agents.image.tagSuffix=jmx
```

## Test Commands

### Agent Status

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status | grep -A 30 "JMX Fetch"
```

### Expected Output (Working)

```
JMX Fetch
=========
  Initialized checks
  ==================
    tomcat
    - instance_name: tomcat-10.244.0.X-9012
      metric_count: 28
      service_check_count: 0
      message: <no value>
      status: OK
```

### JMX List Beans

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent jmx list everything
```

### Check Tomcat Logs

```bash
kubectl logs -n sandbox tomcat-jmx | grep -i jmx
```

## Expected vs Actual

| Behavior | Expected | Actual |
|----------|----------|--------|
| JMX Connection | ✅ OK | ✅ OK |
| Metric Count | ✅ 28+ metrics | ✅ 28 metrics |
| Autodiscovery | ✅ Detects tomcat | ✅ Detects tomcat |

## Common Issues Reproduced

### Issue 1: Connection Refused to 0.0.0.0

**Symptom:**
```
Connection refused to host: 0.0.0.0; nested exception is:
java.net.ConnectException: Connection refused
```

**Cause:** `java.rmi.server.hostname=0.0.0.0` instead of Pod IP.

**Fix:** Use `$(POD_IP)` environment variable:
```yaml
env:
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: CATALINA_OPTS
  value: "-Djava.rmi.server.hostname=$(POD_IP) ..."
```

### Issue 2: Missing JMX Image Tag

**Symptom:** No JMX Fetch section in agent status.

**Cause:** Agent deployed without JMX support.

**Fix:** Add `--set agents.image.tagSuffix=jmx` to Helm install.

### Issue 3: Wrong Port in Autodiscovery

**Symptom:** Connection timeout or refused.

**Cause:** Annotation port doesn't match JMX port.

**Fix:** Ensure annotation port matches `-Dcom.sun.management.jmxremote.port`:
```yaml
annotations:
  ad.datadoghq.com/tomcat.checks: |
    {"tomcat": {"instances": [{"host": "%%host%%", "port": "9012"}]}}
```

## Troubleshooting

```bash
# Pod logs
kubectl logs -n sandbox tomcat-jmx --tail=100

# Agent logs
kubectl logs -n datadog -l app=datadog-agent -c agent --tail=100

# Describe pod
kubectl describe pod -n sandbox tomcat-jmx

# Check JMX connectivity from agent
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent jmx list everything --checks tomcat
```

## Cleanup

```bash
kubectl delete namespace sandbox
helm uninstall datadog-agent -n datadog
kubectl delete namespace datadog
```

## References

- [Autodiscovery with JMX](https://docs.datadoghq.com/containers/guide/autodiscovery-with-jmx/)
- [JMX Integration](https://docs.datadoghq.com/integrations/java/)
- [Troubleshooting JMXFetch](https://datadoghq.atlassian.net/wiki/spaces/TS/pages/328437488) (internal)
- [Agent Docker Tags](https://hub.docker.com/r/datadog/agent/tags)
