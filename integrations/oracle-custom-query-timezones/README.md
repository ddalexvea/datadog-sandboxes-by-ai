# Oracle Custom Queries - Timezone Test

Minimal sandbox to test timezone handling in Datadog Oracle custom queries.

## The Problem

When `TIMESTAMP` columns (without timezone) store data in a local timezone (e.g., São Paulo) but the Oracle database server runs in UTC, custom queries using `SYSTIMESTAMP - INTERVAL` will return incorrect results.

**This is the Oracle equivalent of the [PostgreSQL timezone test](https://github.com/ddalexvea/datadog-agent-postgres-custom-queries-now-timezone).**

## Quick Start

### Step 1: Start minikube

```bash
minikube delete --all
minikube start --memory=4096 --cpus=2
```

### Step 2: Deploy Oracle with Custom Queries

```bash
kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: tz-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oracle
  namespace: tz-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: oracle
  template:
    metadata:
      labels:
        app: oracle
      annotations:
        ad.datadoghq.com/oracle.checks: |
          {
            "oracle": {
              "init_config": {},
              "instances": [{
                "server": "%%host%%",
                "port": 1521,
                "username": "system",
                "password": "testpass",
                "service_name": "FREEPDB1",
                "custom_queries": [
                  {
                    "metric_prefix": "custom.tz_test",
                    "query": "SELECT COUNT(*) as count_value FROM batch_test WHERE created_at >= (SYSTIMESTAMP - INTERVAL '1' HOUR)",
                    "columns": [{"name": "no_fix", "type": "gauge"}],
                    "tags": ["test:no_timezone_fix"]
                  },
                  {
                    "metric_prefix": "custom.tz_test",
                    "query": "SELECT COUNT(*) as count_value FROM batch_test WHERE created_at >= CAST((SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '1' HOUR) AS TIMESTAMP)",
                    "columns": [{"name": "at_timezone", "type": "gauge"}],
                    "tags": ["test:at_timezone"]
                  },
                  {
                    "metric_prefix": "custom.tz_info",
                    "query": "SELECT EXTRACT(TIMEZONE_HOUR FROM SYSTIMESTAMP) as server_tz_offset, TO_NUMBER(TO_CHAR(SYSTIMESTAMP, 'HH24')) as server_hour, TO_NUMBER(TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo', 'HH24')) as saopaulo_hour FROM DUAL",
                    "columns": [{"name": "server_tz_offset", "type": "gauge"}, {"name": "server_hour", "type": "gauge"}, {"name": "saopaulo_hour", "type": "gauge"}],
                    "tags": ["info:timezone"]
                  }
                ]
              }]
            }
          }
    spec:
      containers:
        - name: oracle
          image: gvenzl/oracle-free:23-slim
          ports:
            - containerPort: 1521
          env:
            - name: ORACLE_PASSWORD
              value: "testpass"
            - name: TZ
              value: "UTC"
          resources:
            requests:
              memory: "2Gi"
              cpu: "1"
            limits:
              memory: "4Gi"
              cpu: "2"
---
apiVersion: v1
kind: Service
metadata:
  name: oracle
  namespace: tz-test
spec:
  selector:
    app: oracle
  ports:
    - port: 1521
EOF
```

### Step 3: Wait for Oracle and Create Test Data

```bash
# Oracle takes 1-2 minutes to start
kubectl wait --for=condition=ready pod -l app=oracle -n tz-test --timeout=300s

# Create test table with data stored in São Paulo time
kubectl exec -n tz-test deployment/oracle -- bash -c "sqlplus -s system/testpass@//localhost:1521/FREEPDB1 <<'EOSQL'
CREATE TABLE batch_test (
    id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at TIMESTAMP,
    data VARCHAR2(100)
);
INSERT INTO batch_test (created_at, data) VALUES 
    (CAST(SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo' AS TIMESTAMP), 'recent_1');
INSERT INTO batch_test (created_at, data) VALUES 
    (CAST(SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '30' MINUTE AS TIMESTAMP), 'recent_2');
INSERT INTO batch_test (created_at, data) VALUES 
    (CAST(SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '2' HOUR AS TIMESTAMP), 'old_record');
COMMIT;
EOSQL"
```

### Step 4: Deploy Datadog Agent

```bash
# Create namespace and secret
kubectl create namespace datadog
kubectl create secret generic datadog-secret -n datadog --from-literal=api-key=YOUR_API_KEY

# Add Datadog Helm repository
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Install Datadog Agent
helm upgrade --install datadog-agent datadog/datadog -n datadog \
  --set datadog.apiKeyExistingSecret=datadog-secret \
  --set datadog.site=datadoghq.com \
  --set datadog.kubelet.tlsVerify=false \
  --set clusterAgent.enabled=true \
  --set agents.image.repository=gcr.io/datadoghq/agent \
  --set agents.image.tag=7.59.0 \
  --set agents.image.doNotCheckTag=true
```

### Step 5: Verify Results

```bash
# Wait for agent to start
sleep 60

# Run the Oracle check manually
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent check oracle --table
```

---

## Tested Results

### Custom Metrics from Datadog Agent

```
custom.tz_info.server_tz_offset      gauge  0     info:timezone          # Server is in UTC
custom.tz_info.server_hour           gauge  21    info:timezone          # 21:00 UTC
custom.tz_info.saopaulo_hour         gauge  18    info:timezone          # 18:00 São Paulo (UTC-3)
custom.tz_test.no_fix                gauge  0     test:no_timezone_fix   # ❌ WRONG
custom.tz_test.at_timezone           gauge  2     test:at_timezone       # ✅ CORRECT
```

### Summary Table

| Metric | Value | Method | Correct? |
|--------|-------|--------|----------|
| `custom.tz_info.server_tz_offset` | **0** | Server timezone offset from UTC | ✅ (confirms UTC) |
| `custom.tz_info.server_hour` | **21** | Current hour on server | ✅ |
| `custom.tz_info.saopaulo_hour` | **18** | Current hour in São Paulo | ✅ (3h difference) |
| `custom.tz_test.no_fix` | **0** | `SYSTIMESTAMP - INTERVAL '1' HOUR` | ❌ **WRONG** |
| `custom.tz_test.at_timezone` | **2** | `SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo'` | ✅ **CORRECT** |

### Why the 3-Hour Difference Matters

```
Data stored:     18:00, 17:30, 16:00 (São Paulo time, no timezone info)
                    │      │      │
                    ▼      ▼      ▼
UTC threshold:  ─────────────────────── 20:00 ─── (NO FIX: 0 matches)
                                        
SP threshold:   ────── 17:00 ───────────────────── (AT TIME ZONE: 2 matches)
                    ▲      ▲      
                    │      │      
                 match!  match!
```

---

## The Fix

**Use `AT TIME ZONE` syntax with `CAST` in your Oracle custom query:**

```yaml
custom_queries:
  - metric_prefix: "custom.batch"
    query: |
      SELECT COUNT(*) AS count_value,
             BUSINESS_CLIENT_ID AS client_id
      FROM BATCH_OFFER_SPARK
      WHERE CREATED_AT >= CAST((SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '1' HOUR) AS TIMESTAMP)
      GROUP BY BUSINESS_CLIENT_ID
    columns:
      - name: offer.count
        type: gauge
      - name: business_client_id
        type: tag
```

---

## Key Oracle Syntax Differences (vs PostgreSQL)

| Concept | PostgreSQL | Oracle |
|---------|------------|--------|
| Current timestamp | `NOW()` | `SYSTIMESTAMP` |
| Local timestamp | `NOW()` | `LOCALTIMESTAMP` |
| Convert to timezone | `NOW() AT TIME ZONE 'tz'` | `SYSTIMESTAMP AT TIME ZONE 'tz'` |
| Interval syntax | `INTERVAL '1 hour'` | `INTERVAL '1' HOUR` |
| Cast to timestamp | Implicit | `CAST(... AS TIMESTAMP)` |
| Session timezone | `SET TIME ZONE 'tz'` | `ALTER SESSION SET TIME_ZONE = 'tz'` |
| Timestamp without tz | `TIMESTAMP WITHOUT TIME ZONE` | `TIMESTAMP` |
| Timestamp with tz | `TIMESTAMP WITH TIME ZONE` | `TIMESTAMP WITH TIME ZONE` |

---

## Verification Commands

### Check Oracle Server Timezone

```bash
kubectl exec -n tz-test deployment/oracle -- bash -c "sqlplus -s system/testpass@//localhost:1521/FREEPDB1 <<'EOSQL'
SELECT 
    SYSTIMESTAMP as full_timestamp,
    EXTRACT(TIMEZONE_HOUR FROM SYSTIMESTAMP) as tz_offset_hours,
    TO_CHAR(SYSTIMESTAMP, 'HH24') as server_hour_utc,
    TO_CHAR(SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo', 'HH24') as saopaulo_hour
FROM DUAL;
EOSQL"
```

### Test Queries Manually

```bash
# Query 1: No fix (returns 0 - wrong)
kubectl exec -n tz-test deployment/oracle -- bash -c "sqlplus -s system/testpass@//localhost:1521/FREEPDB1 <<< \"
SELECT COUNT(*) as NO_FIX FROM batch_test WHERE created_at >= (SYSTIMESTAMP - INTERVAL '1' HOUR);
\""

# Query 2: AT TIME ZONE with CAST (returns 2 - correct)
kubectl exec -n tz-test deployment/oracle -- bash -c "sqlplus -s system/testpass@//localhost:1521/FREEPDB1 <<< \"
SELECT COUNT(*) as AT_TIMEZONE FROM batch_test WHERE created_at >= CAST((SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '1' HOUR) AS TIMESTAMP);
\""
```

### Show Detailed Comparison

```bash
kubectl exec -n tz-test deployment/oracle -- bash -c "sqlplus -s system/testpass@//localhost:1521/FREEPDB1 <<'EOSQL'
SET LINESIZE 200
SELECT 
    id,
    TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as data_timestamp,
    CASE 
        WHEN created_at >= (SYSTIMESTAMP - INTERVAL '1' HOUR) THEN 'MATCH (UTC)'
        ELSE 'NO MATCH (UTC)'
    END AS utc_result,
    CASE 
        WHEN created_at >= CAST((SYSTIMESTAMP AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '1' HOUR) AS TIMESTAMP) THEN 'MATCH (SP)'
        ELSE 'NO MATCH (SP)'
    END AS saopaulo_result,
    data
FROM batch_test;
EOSQL"
```

---

## Understanding Oracle Timestamp Types

| Type | Time Zone Aware | Stores | Example |
|------|-----------------|--------|---------|
| `DATE` | No | Date + Time to seconds | `2025-12-31 09:00:00` |
| `TIMESTAMP` | No | Date + Time with fractional seconds | `2025-12-31 09:00:00.123456` |
| `TIMESTAMP WITH TIME ZONE` | Yes | Date + Time + TZ offset | `2025-12-31 09:00:00.123456 +00:00` |
| `TIMESTAMP WITH LOCAL TIME ZONE` | Yes (converted on retrieve) | Stored in DB TZ, shown in session TZ | Varies by session |

---

## Cleanup

```bash
kubectl delete namespace tz-test
kubectl delete namespace datadog
helm uninstall datadog-agent -n datadog
```

---

## References

- [Original PostgreSQL Timezone Test](https://github.com/ddalexvea/datadog-agent-postgres-custom-queries-now-timezone)
- [Datadog Oracle Integration Documentation](https://docs.datadoghq.com/integrations/oracle/)
- [Oracle SYSTIMESTAMP Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/18/sqlrf/SYSTIMESTAMP.html)
- [Oracle Datetime Functions](https://docs.oracle.com/en/database/oracle/oracle-database/23/sqlrf/Datetime-Functions.html)
