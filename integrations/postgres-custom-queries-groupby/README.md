# PostgreSQL Custom Queries Sandbox

A sandbox to reproduce and test Datadog PostgreSQL custom queries with `CREATED_AT` timestamp filters.

## Issue Reproduced

**When using `GROUP BY` with no matching data, the query returns 0 rows and Datadog does NOT emit any metric.**

| Metric Name | WHERE clause | GROUP BY | Rows Returned | Metric Emitted |
|-------------|--------------|----------|---------------|----------------|
| `custom.max.qty` | `= MAX(created_at)` | Yes | 1 row | ✅ Yes |
| `custom.interval.qty` | `>= NOW() - INTERVAL '1 hour'` | Yes | **0 rows** | ❌ **No** |
| `custom.interval_fixed.qty` | `>= NOW() - INTERVAL '1 hour'` | **No** | 1 row (qty=0) | ✅ **Yes** |

## Quick Start

### 1. Start minikube

```bash
minikube start --driver=docker
```

### 2. Create `postgres/postgres-deployment.yaml`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: postgres-demo
  labels:
    tags.datadoghq.com/env: sandbox
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secrets
  namespace: postgres-demo
type: Opaque
stringData:
  POSTGRES_USER: "postgres"
  POSTGRES_PASSWORD: "datadog123"
  POSTGRES_DB: "demo_app"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
  namespace: postgres-demo
data:
  init.sql: |
    CREATE USER datadog WITH PASSWORD 'datadog_password';
    GRANT pg_monitor TO datadog;
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    CREATE SCHEMA IF NOT EXISTS datadog;
    GRANT USAGE ON SCHEMA datadog TO datadog;
    GRANT USAGE ON SCHEMA public TO datadog;
    
    CREATE TABLE test_events (
        id SERIAL PRIMARY KEY,
        name VARCHAR(50),
        created_at TIMESTAMP DEFAULT NOW()
    );
    GRANT SELECT ON test_events TO datadog;
    
    INSERT INTO test_events (name, created_at) VALUES
        ('old_1', NOW() - INTERVAL '5 hours'),
        ('old_2', NOW() - INTERVAL '4 hours'),
        ('old_3', NOW() - INTERVAL '3 hours'),
        ('old_4', NOW() - INTERVAL '2 hours');
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: postgres-demo
  labels:
    app: postgres
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
              "instances": [{
                "dbm": true,
                "host": "%%host%%",
                "port": 5432,
                "username": "datadog",
                "password": "datadog_password",
                "dbname": "demo_app",
                "custom_queries": [
                  {
                    "metric_prefix": "custom.max",
                    "query": "SELECT COUNT(*) AS qty, name AS tag_name FROM test_events WHERE created_at = (SELECT MAX(created_at) FROM test_events) GROUP BY name",
                    "columns": [{"name": "qty", "type": "gauge"}, {"name": "tag_name", "type": "tag"}],
                    "tags": ["query_type:max_with_groupby"]
                  },
                  {
                    "metric_prefix": "custom.interval",
                    "query": "SELECT COUNT(*) AS qty, name AS tag_name FROM test_events WHERE created_at >= (NOW() - INTERVAL '1 hour') GROUP BY name",
                    "columns": [{"name": "qty", "type": "gauge"}, {"name": "tag_name", "type": "tag"}],
                    "tags": ["query_type:interval_with_groupby"]
                  },
                  {
                    "metric_prefix": "custom.interval_fixed",
                    "query": "SELECT COUNT(*) AS qty FROM test_events WHERE created_at >= (NOW() - INTERVAL '1 hour')",
                    "columns": [{"name": "qty", "type": "gauge"}],
                    "tags": ["query_type:interval_no_groupby"]
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
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-secrets
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secrets
                  key: POSTGRES_PASSWORD
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: postgres-secrets
                  key: POSTGRES_DB
          args:
            - "-c"
            - "shared_preload_libraries=pg_stat_statements"
          volumeMounts:
            - name: postgres-init
              mountPath: /docker-entrypoint-initdb.d
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: postgres-init
          configMap:
            name: postgres-init
        - name: postgres-data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: postgres-demo
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
  type: ClusterIP
```

### 3. Create `datadog/values.yaml`

```yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "postgres-lab"
  kubelet:
    tlsVerify: false

clusterAgent:
  enabled: true

agents:
  enabled: true
```

### 4. Deploy

```bash
kubectl apply -f postgres/postgres-deployment.yaml
kubectl create namespace datadog
kubectl create secret generic datadog-secret -n datadog --from-literal=api-key=YOUR_API_KEY
helm upgrade --install datadog-agent datadog/datadog -n datadog -f datadog/values.yaml
```

## Reproduce the Issue

### Check data in PostgreSQL

```bash
kubectl exec -n postgres-demo deploy/postgres -- psql -U datadog -d demo_app -c "SELECT * FROM test_events ORDER BY created_at;"
```

```
 id | name  |         created_at         
----+-------+----------------------------
  1 | old_1 | 2025-12-23 09:45:35.322367
  2 | old_2 | 2025-12-23 10:45:35.322367
  3 | old_3 | 2025-12-23 11:45:35.322367
  4 | old_4 | 2025-12-23 12:45:35.322367
(4 rows)
```

### Query 1: MAX + GROUP BY (works)

```bash
kubectl exec -n postgres-demo deploy/postgres -- psql -U datadog -d demo_app -c \
  "SELECT COUNT(*) AS qty, name AS tag_name FROM test_events WHERE created_at = (SELECT MAX(created_at) FROM test_events) GROUP BY name;"
```

```
 qty | tag_name 
-----+----------
   1 | old_4
(1 row)          ← ✅ 1 row returned → metric emitted
```

### Query 2: INTERVAL + GROUP BY (broken)

```bash
kubectl exec -n postgres-demo deploy/postgres -- psql -U datadog -d demo_app -c \
  "SELECT COUNT(*) AS qty, name AS tag_name FROM test_events WHERE created_at >= (NOW() - INTERVAL '1 hour') GROUP BY name;"
```

```
 qty | tag_name 
-----+----------
(0 rows)         ← ❌ 0 rows returned → NO metric emitted
```

### Query 3: INTERVAL without GROUP BY (fixed)

```bash
kubectl exec -n postgres-demo deploy/postgres -- psql -U datadog -d demo_app -c \
  "SELECT COUNT(*) AS qty FROM test_events WHERE created_at >= (NOW() - INTERVAL '1 hour');"
```

```
 qty 
-----
   0
(1 row)          ← ✅ 1 row returned (value=0) → metric emitted
```

### Check Datadog Agent metrics

```bash
kubectl exec -n datadog $(kubectl get pods -n datadog -l app=datadog-agent -o jsonpath='{.items[0].metadata.name}') \
  -c agent -- agent check postgres --discovery-timeout 15 | grep '"metric": "custom.' | sort -u
```

**Result:**
```
    "metric": "custom.interval_fixed.qty",   ← ✅ Works (no GROUP BY)
    "metric": "custom.max.qty",              ← ✅ Works (MAX always has data)
```

**Missing:** `custom.interval.qty` ❌ (GROUP BY returns 0 rows)

## Root Cause

| Query | GROUP BY | No matching data | Result |
|-------|----------|------------------|--------|
| With GROUP BY | Yes | 0 rows returned | ❌ No metric |
| Without GROUP BY | No | 1 row with value 0 | ✅ Metric emitted |

## Solution

Remove `GROUP BY` to always return 1 row:

```sql
-- ❌ Problem (returns 0 rows when no match):
SELECT COUNT(*) AS qty, column AS tag 
FROM table 
WHERE created_at >= (NOW() - INTERVAL '1 hour') 
GROUP BY column

-- ✅ Fixed (always returns 1 row):
SELECT COUNT(*) AS qty 
FROM table 
WHERE created_at >= (NOW() - INTERVAL '1 hour')
```

## Technical Details

### Why Datadog doesn't emit metrics for 0 rows

The Datadog Agent iterates over query result rows to create metrics. When a query returns 0 rows:
- There are no rows to iterate over
- No metric data points are created
- The metric is simply not emitted

This is **expected behavior** - the Agent cannot emit a value if there's no row containing a value.

### Versions Tested

- PostgreSQL: 15
- Datadog Agent: 7.x
- Helm Chart: datadog/datadog

### Documentation

- [Datadog Custom Queries](https://docs.datadoghq.com/integrations/guide/custom-queries/)
- [PostgreSQL Integration](https://docs.datadoghq.com/integrations/postgres/)
- [Database Monitoring](https://docs.datadoghq.com/database_monitoring/)

## Cleanup

```bash
minikube delete
```
