# sqlserver.database.files.space_used — duplication with two check instances

## Context

When the SQL Server integration is configured with **two instances pointing at the same host** (a pattern from older Datadog recommendations to split DBM vs autodiscovery load), `sqlserver.database.files.space_used` is submitted by both instances. Using `sum` aggregation in dashboards or monitors shows inflated disk usage that can exceed the actual disk size.

The metric comes from `sys.database_files` (per-database view) and is **enabled by default on every instance** via the `db_files_metrics` config key — regardless of whether `dbm` or `database_autodiscovery` is set.

## Environment

- **Agent Version:** 7.x (latest)
- **Platform:** Minikube + Helm
- **Integration:** SQL Server (`connector: odbc`, `driver: ODBC Driver 18 for SQL Server`)

## Schema

```
┌──────────────────────────────────────────────────────┐
│                   Datadog Agent                      │
│                                                      │
│  Instance A (dbm: true)                              │
│  → iterates DEFAULT database (master)                │──► space_used for master's files
│  → db_files_metrics enabled by default              │
│                                                      │
│  Instance B (database_autodiscovery: true)           │
│  → iterates ALL discovered databases                 │──► space_used for ALL databases' files
│  → db_files_metrics enabled by default              │
│                                                      │
│  master's files submitted by BOTH → duplicated       │
└────────────────────────┬─────────────────────────────┘
                         │ both point at
                         ▼
               SQL Server (port 1433)
```

## Quick Start

### 1. Start SQL Server

```bash
docker run -d --name sqlserver-repro \
  -e ACCEPT_EULA=1 \
  -e MSSQL_SA_PASSWORD="YourStrong@Passw0rd" \
  -e MSSQL_PID=Developer \
  -p 1433:1433 \
  mcr.microsoft.com/azure-sql-edge:latest

# Wait ~30s, then create the datadog login
docker run --rm --network container:sqlserver-repro \
  mcr.microsoft.com/mssql-tools:latest \
  /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'YourStrong@Passw0rd' -C -Q "
  IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = 'datadog')
    CREATE LOGIN datadog WITH PASSWORD = 'DatadogPass123!';
  GRANT VIEW SERVER STATE TO datadog;
  GRANT VIEW ANY DEFINITION TO datadog;
  PRINT 'datadog login OK';"
```

### 2. Deploy Datadog Agent (Minikube + Helm)

```bash
minikube start --memory=4096 --cpus=2
kubectl create namespace datadog
kubectl create secret generic datadog-secret -n datadog --from-literal=api-key=$DD_API_KEY

helm repo add datadog https://helm.datadoghq.com && helm repo update
helm install datadog-sql-repro datadog/datadog -n datadog -f values-bug.yaml
kubectl rollout status daemonset/datadog-sql-repro -n datadog --timeout=120s
```

**`values-bug.yaml`** — two instances, same host (replace `<MINIKUBE_GW>` with `minikube ssh "ip route | awk '/default/ {print \$3}'"`)

```yaml
datadog:
  apiKeyExistingSecret: datadog-secret
  site: datadoghq.com
  kubelet:
    tlsVerify: false
  confd:
    sqlserver.yaml: |
      init_config:
      instances:
        - host: <MINIKUBE_GW>,1433
          username: datadog
          password: "DatadogPass123!"
          connector: odbc
          driver: ODBC Driver 18 for SQL Server
          connection_string: "TrustServerCertificate=yes;Trusted_Connection=no;"
          dbm: true
          tags:
            - instance:dbm
          min_collection_interval: 15

        - host: <MINIKUBE_GW>,1433
          username: datadog
          password: "DatadogPass123!"
          connector: odbc
          driver: ODBC Driver 18 for SQL Server
          connection_string: "TrustServerCertificate=yes;Trusted_Connection=no;"
          database_autodiscovery: true
          include_db_fragmentation_metrics: true
          include_task_scheduler_metrics: true
          tags:
            - instance:autodiscovery
          min_collection_interval: 15

clusterAgent:
  enabled: false
agents:
  enabled: true
```

### 3. Run the check

```bash
AGENT_POD=$(kubectl get pod -n datadog -l app=datadog-sql-repro -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n datadog $AGENT_POD -c agent -- agent check sqlserver 2>&1 | grep "space_used" | wc -l
```

## Expected vs Actual

| | Expected | Actual (bug) |
|---|---|---|
| `space_used` submissions per cycle | 1× per database file | **>1×** for files covered by both instances |
| `sum` aggregation in Metrics Explorer | Real disk usage | **inflated** |
| `sum by {host}` | Correct per-host total | **inflated per-host total** |

## Root Cause (confirmed from source code + live repro)

`sqlserver.database.files.space_used` is collected by `SqlserverDatabaseFilesMetrics`, which queries `sys.database_files` for each database in the instance's `self.databases` list.

```python
# integrations-core/sqlserver/datadog_checks/sqlserver/config.py
configurable_metrics = {
    "db_files_metrics": {'enabled': True},  # DEFAULT ON — every instance
    ...
}
```

**What each instance collects:**

| Instance | `self.databases` scope | `space_used` submissions |
|---|---|---|
| Instance A (`dbm: true`, no `database_autodiscovery`) | DEFAULT database only (typically `master`) | Files belonging to `master` |
| Instance B (`database_autodiscovery: true`) | All discovered databases | Files for every discovered database |

**Result:** databases covered by Instance A (at minimum `master`) are also covered by Instance B → those files are submitted **twice**.

### Actual repro output (live test, Azure SQL Edge)

**Bug — 8 submissions:**
```
instance:dbm          | db:master  ← submitted by Instance A
instance:dbm          | db:master  ← submitted by Instance A  (2 files in master)
instance:autodiscovery | db:master  ← ALSO submitted by Instance B  ← duplication
instance:autodiscovery | db:msdb
instance:autodiscovery | db:msdb
instance:autodiscovery | db:msdb
instance:autodiscovery | db:msdb
instance:autodiscovery | db:tempdb
```

`db:master` files appear **from both instances** → `sum by {host}` shows inflated value.

**Fix — 6 submissions (Instance A contributes 0):**
```
instance:autodiscovery | db:master
instance:autodiscovery | db:msdb   (×5)
```

## Fix

Add `database_metrics.db_files_metrics.enabled: false` to **Instance A** (the DBM instance). This is a 3-line addition that preserves the two-instance load-splitting architecture entirely.

**`values-fix.yaml`** — same as `values-bug.yaml`, with one block added to Instance A:

```yaml
        - host: <MINIKUBE_GW>,1433
          username: datadog
          password: "DatadogPass123!"
          connector: odbc
          driver: ODBC Driver 18 for SQL Server
          connection_string: "TrustServerCertificate=yes;Trusted_Connection=no;"
          dbm: true
          database_metrics:         # ← add this block
            db_files_metrics:       #
              enabled: false        #
          tags:
            - instance:dbm
          min_collection_interval: 15
```

```bash
helm upgrade datadog-sql-repro datadog/datadog -n datadog -f values-fix.yaml
kubectl rollout status daemonset/datadog-sql-repro -n datadog --timeout=120s

AGENT_POD=$(kubectl get pod -n datadog -l app=datadog-sql-repro -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n datadog $AGENT_POD -c agent -- agent check sqlserver 2>&1 | grep "space_used" | wc -l
# Should be lower than bug count — Instance A no longer contributes any space_used
```

> **Why not `autodiscovery_exclude`?**
> `autodiscovery_exclude` controls which databases get per-DB metrics (fragmentation, scheduler). It does **not** gate `db_files_metrics`, which has its own `enabled` flag and runs per instance regardless of autodiscovery scope. In environments with user databases, excluding system databases from Instance B still leaves all user databases in scope → Instance B still submits `space_used` alongside Instance A → still inflated.

## Cleanup

```bash
helm uninstall datadog-sql-repro -n datadog
kubectl delete namespace datadog
docker rm -f sqlserver-repro
```

## References

- [integrations-core: database_files_metrics.py](https://github.com/DataDog/integrations-core/blob/master/sqlserver/datadog_checks/sqlserver/database_metrics/database_files_metrics.py)
- [integrations-core: config.py — db_files_metrics default](https://github.com/DataDog/integrations-core/blob/master/sqlserver/datadog_checks/sqlserver/config.py)
- [SQL Server integration conf.yaml.example](https://github.com/DataDog/integrations-core/blob/master/sqlserver/datadog_checks/sqlserver/data/conf.yaml.example)
