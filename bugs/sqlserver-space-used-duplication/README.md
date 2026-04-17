# sqlserver.database.files.space_used — 2× duplication with two check instances

## Context

When the SQL Server integration is configured with **two instances pointing at the same host** (a common pattern from older Datadog recommendations to split DBM vs autodiscovery load), every metric in the `sqlserver.database.files.*` namespace is submitted **twice per collection cycle**. Using `sum` aggregation in dashboards or monitors shows approximately **2× the real disk usage**, sometimes exceeding the actual disk size.

This sandbox reproduces the bug and validates the fix (`autodiscovery_exclude`).

## Environment

- **Agent Version:** 7.x (latest)
- **Platform:** Docker Compose (Azure SQL Edge)
- **Integration:** SQL Server

## Schema

```
┌─────────────────────────────────────┐
│         Datadog Agent               │
│                                     │
│  Instance A  (dbm: true)            │──► space_used submitted (x1)
│  Instance B  (database_autodiscovery)│──► space_used submitted (x1)
│                                     │
│  Same host, same databases          │
│  → 2 submissions per cycle          │
└──────────────────┬──────────────────┘
                   │ both point at
                   ▼
         SQL Server (port 1433)
```

## Quick Start

### 1. Start SQL Server + Agent (bug repro)

Save the two config files below, then:

```bash
export DD_API_KEY=<your_api_key>
docker compose up -d
# Wait ~60s for SQL Server to initialise
docker exec dd-agent-repro agent check sqlserver 2>&1 | grep -A2 "space_used"
```

**`docker-compose.yml`**

```yaml
services:

  sqlserver:
    image: mcr.microsoft.com/azure-sql-edge:latest
    container_name: sqlserver-repro
    environment:
      ACCEPT_EULA: "1"
      MSSQL_SA_PASSWORD: "YourStrong@Passw0rd"
      MSSQL_PID: "Developer"
    ports:
      - "1433:1433"
    volumes:
      - sqlserver-data:/var/opt/mssql
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'YourStrong@Passw0rd' -C -Q 'SELECT 1' > /dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 10
      start_period: 60s

  sqlserver-init:
    image: mcr.microsoft.com/mssql-tools:latest
    container_name: sqlserver-init
    depends_on:
      sqlserver:
        condition: service_healthy
    command:
      - /bin/bash
      - -c
      - |
        /opt/mssql-tools/bin/sqlcmd -S sqlserver -U sa -P 'YourStrong@Passw0rd' -C -Q "
        IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = 'datadog')
          CREATE LOGIN datadog WITH PASSWORD = 'DatadogPass123!';
        GRANT VIEW SERVER STATE TO datadog;
        GRANT VIEW ANY DEFINITION TO datadog;
        PRINT 'datadog login OK';
        "
    restart: "no"

  dd-agent-repro:
    image: gcr.io/datadoghq/agent:latest
    container_name: dd-agent-repro
    environment:
      DD_API_KEY: "${DD_API_KEY}"
      DD_SITE: "datadoghq.com"
    volumes:
      - ./conf.yaml:/etc/datadog-agent/conf.d/sqlserver.d/conf.yaml

volumes:
  sqlserver-data:
```

**`conf.yaml`** — bug: two instances, same host

```yaml
init_config:

instances:
  - host: sqlserver-repro,1433
    username: datadog
    password: "DatadogPass123!"
    connector: odbc
    driver: ODBC Driver 18 for SQL Server
    connection_string: "TrustServerCertificate=yes;Trusted_Connection=no;"
    dbm: true
    tags:
      - instance:A

  - host: sqlserver-repro,1433
    username: datadog
    password: "DatadogPass123!"
    connector: odbc
    driver: ODBC Driver 18 for SQL Server
    connection_string: "TrustServerCertificate=yes;Trusted_Connection=no;"
    database_autodiscovery: true
    include_db_fragmentation_metrics: true
    include_task_scheduler_metrics: true
    tags:
      - instance:B
```

## Expected vs Actual

| | Expected | Actual (bug) |
|---|---|---|
| `sqlserver.database.files.space_used` submissions per cycle | 1× per database file | **2×** per database file |
| `sum` aggregation in Metrics Explorer | Real disk usage | **~2× real disk usage** |
| `by {host}` aggregation | Correct per-host total | **2× per-host total** |

### Verify the duplication

```bash
# Count how many space_used points are submitted in one check run
docker exec dd-agent-repro agent check sqlserver 2>&1 | grep "space_used" | wc -l
# Bug:  8 lines  (4 database files × 2 instances)
# Fix:  4 lines  (4 database files × 1 instance)
```

## Root Cause (source code)

`sqlserver.database.files.space_used` comes from **`sys.database_files`** (a per-database view), which is queried for each database in the instance's `self.databases` list. The controlling config key is `db_files_metrics`, which is **enabled by default (`True`) on every instance** — regardless of `database_autodiscovery` or `dbm` settings.

```python
# integrations-core/sqlserver/datadog_checks/sqlserver/config.py
configurable_metrics = {
    "db_files_metrics": {'enabled': True},  # ← DEFAULT ON for every instance
    ...
}
```

Both instances iterate all databases and submit `space_used` once per file → **2× total**.

## Fix

Disable `db_files_metrics` on **Instance A** (the DBM instance). This lets Instance B (with full `database_autodiscovery`) remain the single source for `space_used` across all discovered databases.

**`conf.yaml`** — fixed: add `database_metrics` block to Instance A

```yaml
init_config:

instances:
  - host: sqlserver-repro,1433
    username: datadog
    password: "DatadogPass123!"
    connector: odbc
    driver: ODBC Driver 18 for SQL Server
    connection_string: "TrustServerCertificate=yes;Trusted_Connection=no;"
    dbm: true
    database_metrics:
      db_files_metrics:
        enabled: false       # ← add this block
    tags:
      - instance:A

  - host: sqlserver-repro,1433
    username: datadog
    password: "DatadogPass123!"
    connector: odbc
    driver: ODBC Driver 18 for SQL Server
    connection_string: "TrustServerCertificate=yes;Trusted_Connection=no;"
    database_autodiscovery: true
    include_db_fragmentation_metrics: true
    include_task_scheduler_metrics: true
    tags:
      - instance:B
```

> **Why not `autodiscovery_exclude`?** `autodiscovery_exclude` controls which databases get per-DB metrics like fragmentation and scheduler — it does NOT gate the `db_files_metrics` collection, which runs independently per instance. Excluding system databases still leaves all user databases in scope on Instance B, so both instances continue submitting `space_used` for all user DBs → still 2×.

### Verify the fix

```bash
docker exec dd-agent-repro agent check sqlserver 2>&1 | grep "space_used" | wc -l
# Bug:  8 lines  (4 files × 2 instances)
# Fix:  4 lines  (4 files × 1 instance — only Instance B)
```

## Cleanup

```bash
docker compose down -v
```

## References

- [SQL Server integration conf.yaml.example](https://github.com/DataDog/integrations-core/blob/master/sqlserver/datadog_checks/sqlserver/data/conf.yaml.example)
- [autodiscovery_exclude parameter docs](https://docs.datadoghq.com/integrations/sqlserver/)
