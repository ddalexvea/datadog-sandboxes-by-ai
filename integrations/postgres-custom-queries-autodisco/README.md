# PostgreSQL: Custom Queries Do NOT Work with Database Autodiscovery

## Issue

When using `database_autodiscovery` with the Datadog PostgreSQL integration, `custom_queries` only run on the connection database (default: `postgres`), **not** on all autodiscovered databases.

## What Works vs What Doesn't

| Feature | Works with `database_autodiscovery`? |
|---------|-------------------------------------|
| PostgreSQL integration metrics | ✅ Yes |
| DBM (query samples, explain plans, metadata) | ✅ Yes |
| `custom_queries` | ❌ **No** |

## Why It Doesn't Work

1. `custom_queries` execute on the database specified in `dbname`
2. If `dbname` is not set, it defaults to `postgres`
3. `database_autodiscovery` does **not** affect which database `custom_queries` run on
4. There is **no** `databases` parameter in `custom_queries` - it doesn't exist in the [official conf.yaml.example](https://github.com/DataDog/integrations-core/blob/master/postgres/datadog_checks/postgres/data/conf.yaml.example)

---

## Reproduce the Issue

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
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secrets
  namespace: postgres-demo
type: Opaque
stringData:
  POSTGRES_USER: "postgres"
  POSTGRES_PASSWORD: "postgres123"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
  namespace: postgres-demo
data:
  01-init.sql: |
    -- Create datadog user
    CREATE USER datadog WITH PASSWORD 'datadog_password';
    GRANT pg_monitor TO datadog;

    -- Create additional databases
    CREATE DATABASE app_db;
    CREATE DATABASE analytics_db;

  02-init-app-db.sh: |
    #!/bin/bash
    psql -U postgres -d app_db -c "
    GRANT USAGE ON SCHEMA public TO datadog;
    CREATE TABLE users (id SERIAL PRIMARY KEY, name VARCHAR(100));
    CREATE TABLE orders (id SERIAL PRIMARY KEY, user_id INT, amount DECIMAL);
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO datadog;
    "

  03-init-analytics-db.sh: |
    #!/bin/bash
    psql -U postgres -d analytics_db -c "
    GRANT USAGE ON SCHEMA public TO datadog;
    CREATE TABLE events (id SERIAL PRIMARY KEY, event_type VARCHAR(50));
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO datadog;
    "
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-instance-test
  namespace: postgres-demo
  labels:
    app: postgres-instance-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-instance-test
  template:
    metadata:
      labels:
        app: postgres-instance-test
      annotations:
        ad.datadoghq.com/postgres.checks: |
          {
            "postgres": {
              "init_config": {},
              "instances": [{
                "host": "%%host%%",
                "port": 5432,
                "username": "datadog",
                "password": "datadog_password",
                "dbm": true,
                "collect_default_database": false,
                "database_autodiscovery": {
                  "enabled": true,
                  "exclude": ["template0", "template1"]
                },
                "tags": ["test_type:instance-level"],
                "custom_queries": [{
                  "metric_prefix": "postgresql",
                  "query": "SELECT current_database() AS database_name, COUNT(*) AS table_count FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema')",
                  "columns": [
                    {"name": "database_name", "type": "tag"},
                    {"name": "table_count", "type": "gauge"}
                  ],
                  "tags": ["query:table_count"]
                }]
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
          args: ["-c", "shared_preload_libraries=pg_stat_statements"]
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
            - name: postgres-init
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: postgres-data
          emptyDir: {}
        - name: postgres-init
          configMap:
            name: postgres-init
            defaultMode: 0755
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-instance-test
  namespace: postgres-demo
spec:
  selector:
    app: postgres-instance-test
  ports:
    - port: 5432
```

### 3. Create `datadog/values-simple.yaml`

```yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "postgres-autodiscovery-lab"
  kubelet:
    tlsVerify: false

clusterAgent:
  enabled: true

agents:
  enabled: true
```

### 4. Deploy PostgreSQL

```bash
kubectl apply -f postgres/postgres-deployment.yaml
```

### 5. Wait for pod to be ready

```bash
kubectl wait --for=condition=ready pod -l app=postgres-instance-test -n postgres-demo --timeout=120s
```

The init scripts will automatically create:
- `datadog` user with password `datadog_password`
- `app_db` database with 2 tables (users, orders)
- `analytics_db` database with 1 table (events)

### 6. Verify databases exist

```bash
kubectl exec -n postgres-demo deploy/postgres-instance-test -- psql -U postgres -c "\l"
```

**Expected output:**

```
                                                      List of databases
     Name      |  Owner   | Encoding |  Collate   |   Ctype    | ICU Locale | Locale Provider |   Access privileges   
---------------+----------+----------+------------+------------+------------+-----------------+-----------------------
 analytics_db  | postgres | UTF8     | en_US.utf8 | en_US.utf8 |            | libc            | 
 app_db        | postgres | UTF8     | en_US.utf8 | en_US.utf8 |            | libc            | 
 postgres      | postgres | UTF8     | en_US.utf8 | en_US.utf8 |            | libc            | 
 template0     | postgres | UTF8     | en_US.utf8 | en_US.utf8 |            | libc            | =c/postgres          +
               |          |          |            |            |            |                 | postgres=CTc/postgres
 template1     | postgres | UTF8     | en_US.utf8 | en_US.utf8 |            | libc            | =c/postgres          +
               |          |          |            |            |            |                 | postgres=CTc/postgres
(5 rows)
```

### 7. Deploy Datadog Agent

```bash
kubectl create namespace datadog
kubectl create secret generic datadog-secret -n datadog --from-literal=api-key=YOUR_API_KEY
helm upgrade --install datadog-agent datadog/datadog -n datadog -f datadog/values-simple.yaml
```

Wait for agent:

```bash
sleep 60
kubectl get pods -n datadog
```

### 8. Check custom metrics collected

```bash
kubectl exec -n datadog $(kubectl get pods -n datadog -l app=datadog-agent -o jsonpath='{.items[0].metadata.name}') \
  -c agent -- agent check postgres --discovery-timeout 10 2>&1 | grep -B5 -A20 '"metric": "postgresql.table_count"'
```

**Actual output (PROBLEM):**

```json
{
  "metric": "postgresql.table_count",
  "points": [[1766503844, 0]],
  "tags": [
    "database_name:postgres",     // ← Only postgres!
    "db:postgres",
    "test_type:instance-level",
    ...
  ]
}
```

**Expected output (if it worked):**

```json
// Should see 3 metrics:
{"metric": "postgresql.table_count", "tags": ["database_name:postgres"], "value": 0}
{"metric": "postgresql.table_count", "tags": ["database_name:app_db"], "value": 2}
{"metric": "postgresql.table_count", "tags": ["database_name:analytics_db"], "value": 1}
```

---

## Workaround

Create **separate instances** for each database where you need custom queries:

```yaml
instances:
  # Instance 1: DBM + Autodiscovery (for standard metrics and DBM)
  - host: 'your-postgres-host'
    port: 5432
    username: 'datadog'
    password: 'xxx'
    dbm: true
    database_autodiscovery:
      enabled: true
      exclude:
        - template0
        - template1

  # Instance 2: Custom queries for 'app_db'
  - host: 'your-postgres-host'
    port: 5432
    username: 'datadog'
    password: 'xxx'
    dbname: 'app_db'                # ← Target database
    only_custom_queries: true       # ← Only run custom queries (no duplicate metrics)
    custom_queries:
      - metric_prefix: postgresql
        query: |
          SELECT current_database() AS database_name, 
                 COUNT(*) AS table_count 
          FROM information_schema.tables 
          WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        columns:
          - name: database_name
            type: tag
          - name: table_count
            type: gauge

  # Instance 3: Custom queries for 'analytics_db'
  - host: 'your-postgres-host'
    port: 5432
    username: 'datadog'
    password: 'xxx'
    dbname: 'analytics_db'          # ← Different database
    only_custom_queries: true
    custom_queries:
      - metric_prefix: postgresql
        query: |
          SELECT current_database() AS database_name, 
                 COUNT(*) AS table_count 
          FROM information_schema.tables 
          WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        columns:
          - name: database_name
            type: tag
          - name: table_count
            type: gauge
```

## Key Configuration Options

| Option | Purpose |
|--------|---------|
| `dbname` | Specifies which database to connect to and run custom queries on |
| `only_custom_queries: true` | Only runs custom queries, skips standard metrics (prevents duplicates) |
| `database_autodiscovery` | Only affects standard integration metrics and DBM, not custom queries |

## Cleanup

```bash
kubectl delete namespace postgres-demo
kubectl delete namespace datadog
minikube delete
```

## References

- [Datadog PostgreSQL conf.yaml.example](https://github.com/DataDog/integrations-core/blob/master/postgres/datadog_checks/postgres/data/conf.yaml.example)
- [only_custom_queries parameter](https://github.com/DataDog/integrations-core/blob/master/postgres/datadog_checks/postgres/data/conf.yaml.example#L284)
- [Database Monitoring Setup](https://docs.datadoghq.com/database_monitoring/setup_postgres/)
