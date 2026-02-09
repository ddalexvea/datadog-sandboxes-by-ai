# PostgreSQL Custom Queries - Timezone Test

Minimal sandbox to test timezone handling in Datadog PostgreSQL custom queries.

## The Problem

When `TIMESTAMP WITHOUT TIME ZONE` columns store data in a local timezone (e.g., São Paulo) but the PostgreSQL server runs in UTC, custom queries using `NOW() - INTERVAL` will return incorrect results.

## Quick Start

### Step 1: Start minikube

```bash
minikube start
```

### Step 2: Deploy PostgreSQL with Custom Queries and Test Data

```bash
kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: tz-test
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
  namespace: tz-test
data:
  init.sql: |
    -- Create test table (TIMESTAMP WITHOUT TIME ZONE - like customer's table)
    CREATE TABLE batch_test (
        id SERIAL PRIMARY KEY,
        created_at TIMESTAMP WITHOUT TIME ZONE,
        data TEXT
    );
    
    -- Insert data as if app writes in São Paulo time (UTC-3)
    -- This simulates: app runs at 01:00 São Paulo, inserts local timestamp
    INSERT INTO batch_test (created_at, data) VALUES 
        (NOW() AT TIME ZONE 'America/Sao_Paulo', 'recent_1'),
        (NOW() AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '30 minutes', 'recent_2'),
        (NOW() AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '2 hours', 'old_record');
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: tz-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
      annotations:
        ad.datadoghq.com/postgres.checks: |
          {
            "postgres": {
              "init_config": {},
              "instances": [{
                "host": "%%host%%",
                "port": 5432,
                "username": "postgres",
                "password": "testpass",
                "dbname": "postgres",
                "custom_queries": [
                  {
                    "metric_prefix": "custom.tz_test",
                    "query": "SELECT COUNT(*) as count_value FROM batch_test WHERE created_at >= (NOW() - INTERVAL '1 hour')",
                    "columns": [{"name": "no_fix", "type": "gauge"}],
                    "tags": ["test:no_timezone_fix"]
                  },
                  {
                    "metric_prefix": "custom.tz_test",
                    "query": "SET TIME ZONE 'America/Sao_Paulo'; SELECT COUNT(*) as count_value FROM batch_test WHERE created_at >= (NOW() - INTERVAL '1 hour')",
                    "columns": [{"name": "set_timezone", "type": "gauge"}],
                    "tags": ["test:set_timezone"]
                  },
                  {
                    "metric_prefix": "custom.tz_test",
                    "query": "SELECT COUNT(*) as count_value FROM batch_test WHERE created_at >= (NOW() AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '1 hour')",
                    "columns": [{"name": "at_timezone", "type": "gauge"}],
                    "tags": ["test:at_timezone"]
                  }
                ]
              }]
            }
          }
    spec:
      containers:
        - name: postgres
          image: postgres:15
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_PASSWORD
              value: "testpass"
          args:
            - "-c"
            - "timezone=UTC"
          volumeMounts:
            - name: postgres-init
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: postgres-init
          configMap:
            name: postgres-init
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: tz-test
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
EOF
```

### Step 3: Wait for PostgreSQL

```bash
kubectl wait --for=condition=ready pod -l app=postgres -n tz-test --timeout=120s
```

### Step 4: Deploy Datadog Agent

Create the values file:

```yaml
# datadog/values.yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "tz-test-cluster"
  kubelet:
    tlsVerify: false

clusterAgent:
  enabled: true

agents:
  enabled: true
```

Deploy:

```bash
# Create namespace and secret
kubectl create namespace datadog
kubectl create secret generic datadog-secret -n datadog --from-literal=api-key=YOUR_API_KEY

# Add Datadog Helm repository
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Install Datadog Agent
helm upgrade --install datadog-agent datadog/datadog -n datadog -f datadog/values.yaml
```

### Step 5: Verify Results

```bash
# Wait for agent
sleep 60

# Check for errors in custom queries
kubectl logs -n datadog daemonset/datadog-agent -c agent | grep -E "Error.*custom|tz_test"

# Check postgres check status
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status | grep -A 15 "postgres"
```

---

## Expected Results

| Query # | Method | Datadog Result | Value |
|---------|--------|----------------|-------|
| 1 | No fix (UTC) | ✅ Works | **0** (wrong) |
| 2 | `SET TIME ZONE` | ❌ **FAILS** | Error |
| 3 | `AT TIME ZONE` | ✅ Works | **2** (correct) |

### Datadog UI Result

Only queries #1 and #3 appear in Datadog. Query #2 fails silently (no metric sent).

![Datadog UI showing custom.tz_test metrics](https://github.com/ddalexvea/datadog-agent-postgres-custom-queries-now-timezone/blob/main/datadog-ui-result.png?raw=true)

### Query 2 Error

The Agent logs show this error for query #2:

```
2025-12-31 09:08:06 UTC | CORE | ERROR | (pkg/collector/python/datadog_agent.go:143 in LogMessage) | postgres:13d26ee6c714eb9c | (core.py:94) | Error querying custom query #2: the last operation didn't produce records (command status: SET)
```

Full stack trace:

```
raise e.ProgrammingError(
psycopg.ProgrammingError: the last operation didn't produce records (command status: SET)
```

**Why?** Datadog executes the query and expects rows back. `SET TIME ZONE` is a command that returns "SET" (not rows), so the Agent's psycopg driver raises an error.

---

## The Fix

**Use `AT TIME ZONE` syntax in your custom query:**

```yaml
custom_queries:
  - metric_prefix: "custom.batch"
    query: |
      SELECT COUNT(*) AS count_value,
             BUSINESS_CLIENT_ID AS client_id
      FROM BATCH_OFFER_SPARK
      WHERE CREATED_AT >= (NOW() AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '1 hour')
      GROUP BY BUSINESS_CLIENT_ID
    columns:
      - name: offer.count
        type: gauge
      - name: business_client_id
        type: tag
```

---

## Verification Commands

### Check PostgreSQL Server Timezone

```bash
kubectl exec -n tz-test deployment/postgres -- psql -U postgres -c "
SELECT 
    current_setting('TIMEZONE') AS server_timezone,
    NOW() AS server_now,
    NOW() AT TIME ZONE 'America/Sao_Paulo' AS sao_paulo_now;
"
```

Expected output (server in UTC):

```
 server_timezone |           server_now           |       sao_paulo_now        
-----------------+-------------------------------+----------------------------
 Etc/UTC         | 2025-12-31 09:00:00.000000+00 | 2025-12-31 06:00:00.000000
```

### Check Data vs NOW() Comparison

```bash
kubectl exec -n tz-test deployment/postgres -- psql -U postgres -c "
SELECT 
    created_at AS data_timestamp,
    NOW() AS utc_now,
    (NOW() - INTERVAL '1 hour') AS utc_compare,
    (NOW() AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '1 hour') AS saopaulo_compare,
    CASE 
        WHEN created_at >= (NOW() - INTERVAL '1 hour') THEN 'MATCH (UTC)'
        ELSE 'NO MATCH (UTC)'
    END AS utc_result,
    CASE 
        WHEN created_at >= (NOW() AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '1 hour') THEN 'MATCH (SP)'
        ELSE 'NO MATCH (SP)'
    END AS saopaulo_result
FROM batch_test;
"
```

### Test queries manually via psql

```bash
# Query 1: No fix (returns 0 - wrong)
kubectl exec -n tz-test deployment/postgres -- psql -U postgres -c "
SELECT COUNT(*) FROM batch_test WHERE created_at >= (NOW() - INTERVAL '1 hour');
"

# Query 2: SET TIME ZONE (returns 2 - works in psql, NOT in Datadog)
kubectl exec -n tz-test deployment/postgres -- psql -U postgres -c "
SET TIME ZONE 'America/Sao_Paulo';
SELECT COUNT(*) FROM batch_test WHERE created_at >= (NOW() - INTERVAL '1 hour');
"

# Query 3: AT TIME ZONE (returns 2 - works everywhere)
kubectl exec -n tz-test deployment/postgres -- psql -U postgres -c "
SELECT COUNT(*) FROM batch_test WHERE created_at >= (NOW() AT TIME ZONE 'America/Sao_Paulo' - INTERVAL '1 hour');
"
```

---

## Cleanup

```bash
kubectl delete namespace tz-test
kubectl delete namespace datadog
helm uninstall datadog-agent -n datadog
```
