# Ticket 2484845 - Sequential Log Monitoring Sandbox

## Issue Summary

**Customer wants to monitor a two-log sequence:**
1. File transfer progress log for `fflynsl-*.txt` 
2. "Done Transferring [1] files" message within 1-2 seconds
3. Alert ONLY if both logs occur in sequence with the same file correlation

**Problem**: Customer tried using **Transactions feature** in Log Explorer but cannot find "Group into Transactions" option in Monitor UI.

## Sandbox Environment

This sandbox reproduces the customer's scenario in Minikube with Colima.

### Architecture
- **Minikube** (1 node cluster) running on **Colima** (Docker runtime)
- **Datadog Agent** with log collection enabled
- **Test Pod** generating sequential logs every 15 seconds

## Quick Start

### Prerequisites
```bash
# Check if Colima and Minikube are running
colima status
minikube status
```

### Start Environment (if not running)
```bash
# Use Warp workflow
#minikube-colima

# Or manually
colima start --cpu 4 --memory 8 --disk 30
minikube start --driver=docker --cpus=2 --memory=3500
```

### Deploy Everything
```bash
cd /path/to/sandbox

# 1. Create secret with your API key
kubectl create secret generic datadog-secret --from-literal=api-key=<YOUR_API_KEY>

# 2. Deploy log simulator
kubectl apply -f k8s-deployment.yaml

# 3. Deploy Datadog Agent
helm repo add datadog https://helm.datadoghq.com
helm repo update
helm install datadog-agent -f values.yaml datadog/datadog --namespace default

# 4. Check status
kubectl get pods --all-namespaces
```

## View Logs

### View simulator logs locally
```bash
kubectl logs -n sequential-logs-test file-transfer-simulator -f
```

### Check Datadog Agent status
```bash
# Get agent pod name
AGENT_POD=$(kubectl get pods -l app.kubernetes.io/name=datadog -o jsonpath='{.items[0].metadata.name}')

# Check agent status
kubectl exec -it $AGENT_POD -- agent status

# Check log collection
kubectl exec -it $AGENT_POD -- agent status | grep -A 20 "Log Agent"
```

## Expected Log Pattern

The simulator generates this sequence every 15 seconds:

```
2026-02-01 17:06:01 INFO [ingService_Worker-13] .j.f.DailyFilesFTPJob$LogProgressMonitor : [][] : File [fflynsl-20260201-17-06.txt] bytes transferred [1285078]
2026-02-01 17:06:02 INFO [ingService_Worker-13] .j.f.DailyFilesFTPJob$LogProgressMonitor : [][] : File [fflynsl-20260201-17-06.txt] bytes transferred [3604425]
2026-02-01 17:06:02 INFO [ingService_Worker-13] .j.f.DailyFilesFTPJob$LogProgressMonitor : [][] : File [fflynsl-20260201-17-06.txt] bytes transferred [5285078]
2026-02-01 17:06:03 INFO [ingService_Worker-13] f.s.j.f.DailyFilesFTPJob : [][] : Done Transferring [1] files.
2026-02-01 17:06:03 INFO [ingService_Worker-13] f.s.j.f.DailyFilesFTPJob : [][] : Quitting client
2026-02-01 17:06:04 INFO [ingService_Worker-13] f.s.j.f.DailyFilesFTPJob : [][] : Complete
```

**Key timing**: "Done Transferring" appears ~1-2 seconds after the last file transfer log.

## Testing in Datadog UI

### 1. Verify Logs in Explorer
- Go to **Logs → Explorer**
- Filter: `service:ftp-job` or `kube_namespace:sequential-logs-test`
- You should see the sequential pattern repeating

### 2. Test Transactions Feature (Log Explorer)
- In Log Explorer, try grouping/analyzing the sequence
- **Expected**: Transactions feature works for analysis ✅

### 3. Try Creating Monitor with Transactions
- Go to **Monitors → New Monitor → Logs**
- Try to find "Group into Transactions" option
- **Expected**: Feature NOT available in Monitor UI ❌

## Customer Solutions to Test

### Option 1: Composite Monitor ⚠️
Create two separate log monitors and combine them:
1. **Monitor A**: Detect file transfer logs with pattern `File [fflynsl`
2. **Monitor B**: Detect "Done Transferring [1] files"
3. **Composite**: Alert if both trigger within 2 minutes

**Limitation**: Cannot correlate by filename, may get false positives.

### Option 2: Log-to-Metrics ✅ (Recommended)
1. Create a metric from the log pattern
2. Use tags to include filename
3. Create metric-based monitor for sequential detection

### Option 3: Log Pattern with Time Aggregation
Use log query with aggregation:
```
service:ftp-job ("File [fflynsl" AND "Done Transferring")
```

**Limitation**: Cannot enforce strict 1-2 second timing.

## Files in This Sandbox

- `k8s-deployment.yaml` - Kubernetes pod generating sequential logs
- `values.yaml` - Helm values for Datadog Agent
- `README.md` - This file

## Useful Commands

```bash
# View all pods
kubectl get pods --all-namespaces

# Follow simulator logs
kubectl logs -n sequential-logs-test file-transfer-simulator -f

# Check Datadog Agent logs
AGENT_POD=$(kubectl get pods -l app.kubernetes.io/name=datadog -o jsonpath='{.items[0].metadata.name}')
kubectl logs $AGENT_POD -f

# Restart simulator
kubectl delete pod -n sequential-logs-test file-transfer-simulator
kubectl apply -f k8s-deployment.yaml

# Restart Datadog Agent
helm upgrade datadog-agent -f values.yaml datadog/datadog --namespace default
```

## Cleanup

```bash
# Remove Datadog Agent
helm uninstall datadog-agent --namespace default

# Remove test pod
kubectl delete -f k8s-deployment.yaml

# Delete namespace
kubectl delete namespace sequential-logs-test

# Stop Minikube and Colima (optional)
minikube stop
colima stop
```

## Links

- **Zendesk Ticket**: [#2484845](https://datadog.zendesk.com/agent/tickets/2484845)
- **Customer Org**: FIX Flyer, LLC d.b.a FlyerFT
- **Datadog Docs - Transactions**: https://docs.datadoghq.com/logs/explorer/analytics/transactions/
- **Datadog Docs - Log Monitors**: https://docs.datadoghq.com/monitors/types/log/

---

**Created**: 2026-02-01  
**Engineer**: Alexandre VEA  
**Status**: ✅ Sandbox Ready
