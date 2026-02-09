# SQL Server + Datadog Integration Lab with Custom Queries

Complete lab setup for monitoring SQL Server on Kubernetes with Datadog Agent, featuring custom metric collection based on the [official Datadog documentation](https://docs.datadoghq.com/integrations/guide/collect-sql-server-custom-metrics).

## 🎯 Overview

This lab demonstrates:
- **SQL Server 2022** deployment on Minikube
- **Datadog Agent** installation via Helm with SQL Server integration
- **Autodiscovery annotations v2** for automatic integration configuration
- **Custom SQL queries** to collect business metrics from application data
- Working solution for ODBC Driver 18 SSL certificate issues

## 📋 Prerequisites

- Minikube installed and running
- kubectl configured
- Helm 3.x installed
- Datadog API key

## 🚀 Quick Start

### 1. Start Minikube

```bash
minikube start --driver=docker --cpus=4 --memory=7000
```

### 2. Create Datadog Namespace and Secret

```bash
kubectl create namespace datadog

kubectl create secret generic datadog-secret \
  --from-literal api-key=YOUR_DATADOG_API_KEY \
  -n datadog
```

### 3. Install Datadog Agent

Create `datadog-values.yaml`:

```yaml
datadog:
  site: "datadoghq.com"
  apiKeyExistingSecret: "datadog-secret"
  clusterName: "sqlserver-lab"
  kubelet:
    tlsVerify: false
  logs:
    enabled: true
    containerCollectAll: true

clusterAgent:
  enabled: true

agents:
  enabled: true
```

Install with Helm:

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update

helm install datadog-agent datadog/datadog \
  -f datadog-values.yaml \
  -n datadog
```

### 4. Deploy SQL Server with Datadog Integration

Create `sqlserver-deployment.yaml`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: sqlserver-init
  namespace: default
data:
  init.sql: |
    -- Create Datadog user
    CREATE LOGIN datadog WITH PASSWORD = 'Password123!';
    CREATE USER datadog FOR LOGIN datadog;
    GRANT SELECT on sys.dm_os_performance_counters to datadog;
    GRANT VIEW SERVER STATE to datadog;
    GRANT VIEW ANY DEFINITION to datadog;
    GO

    -- Create test database
    CREATE DATABASE testdb;
    GO

    USE testdb;
    GO

    -- Create orders table
    CREATE TABLE orders (
        order_id INT PRIMARY KEY IDENTITY(1,1),
        customer_name VARCHAR(100),
        order_date DATETIME DEFAULT GETDATE(),
        total_amount DECIMAL(10,2),
        status VARCHAR(20)
    );
    GO

    -- Insert sample data
    INSERT INTO orders (customer_name, total_amount, status) VALUES
    ('Alice Johnson', 150.50, 'completed'),
    ('Bob Smith', 200.00, 'completed'),
    ('Charlie Brown', 75.25, 'pending'),
    ('Diana Prince', 300.00, 'completed'),
    ('Eve Adams', 120.75, 'cancelled');
    GO

    -- Grant access to testdb
    USE testdb;
    GO
    CREATE USER datadog FOR LOGIN datadog;
    GRANT SELECT ON SCHEMA::dbo TO datadog;
    GO
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sqlserver
  namespace: default
  labels:
    app: sqlserver
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sqlserver
  template:
    metadata:
      labels:
        app: sqlserver
        tags.datadoghq.com/service: "sqlserver"
        tags.datadoghq.com/env: "lab"
      annotations:
        ad.datadoghq.com/sqlserver.checks: |
          {
            "sqlserver": {
              "init_config": {},
              "instances": [
                {
                  "host": "%%host%%,1433",
                  "username": "datadog",
                  "password": "Password123!",
                  "connector": "odbc",
                  "driver": "ODBC Driver 18 for SQL Server",
                  "connection_string": "TrustServerCertificate=yes;Trusted_Connection=no;",
                  "tags": ["env:lab", "cluster:sqlserver-lab"],
                  "custom_queries": [
                    {
                      "query": "SELECT status, COUNT(*) as order_count, SUM(total_amount) as total_revenue FROM testdb.dbo.orders GROUP BY status",
                      "columns": [
                        {"name": "status", "type": "tag"},
                        {"name": "order.count", "type": "gauge"},
                        {"name": "order.revenue", "type": "gauge"}
                      ],
                      "tags": ["query:order_stats"]
                    },
                    {
                      "query": "SELECT COUNT(*) as pending_orders FROM testdb.dbo.orders WHERE status = 'pending'",
                      "columns": [
                        {"name": "order.pending_count", "type": "gauge"}
                      ],
                      "tags": ["query:pending_orders"]
                    }
                  ]
                }
              ]
            }
          }
        ad.datadoghq.com/sqlserver.logs: '[{"source": "sqlserver", "service": "sqlserver"}]'
    spec:
      containers:
      - name: sqlserver
        image: mcr.microsoft.com/mssql/server:2022-latest
        ports:
        - containerPort: 1433
          name: sqlserver
        env:
        - name: ACCEPT_EULA
          value: "Y"
        - name: SA_PASSWORD
          value: "YourStrong@Passw0rd"
        - name: MSSQL_PID
          value: "Developer"
        resources:
          requests:
            memory: "2Gi"
            cpu: "1000m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        volumeMounts:
        - name: init-script
          mountPath: /docker-entrypoint-initdb.d
      volumes:
      - name: init-script
        configMap:
          name: sqlserver-init
---
apiVersion: v1
kind: Service
metadata:
  name: sqlserver
  namespace: default
spec:
  selector:
    app: sqlserver
  ports:
  - protocol: TCP
    port: 1433
    targetPort: 1433
  type: ClusterIP
```

Deploy SQL Server:

```bash
kubectl apply -f sqlserver-deployment.yaml
```

### 5. Initialize the Database

Wait for the pod to be ready:

```bash
kubectl wait --for=condition=ready pod -l app=sqlserver --timeout=180s
```

Initialize the database:

```bash
kubectl exec deployment/sqlserver -- \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'YourStrong@Passw0rd' -C \
  -i /docker-entrypoint-initdb.d/init.sql
```

Grant testdb permissions:

```bash
kubectl exec deployment/sqlserver -- \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'YourStrong@Passw0rd' -C \
  -Q "USE testdb; CREATE USER datadog FOR LOGIN datadog; GRANT SELECT ON SCHEMA::dbo TO datadog;"
```

## ✅ Verification

### Check Datadog Agent Status

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- \
  agent status | grep -A 20 "sqlserver"
```

Expected output:
```
sqlserver (22.9.1)
------------------
  Instance ID: sqlserver:xxxxx [OK]
  Total Runs: X
  Metric Samples: Last Run: 264+
  Service Checks: Last Run: 1
  Average Execution Time : ~60ms
  Last Successful Execution Date : <timestamp>
```

### Run Manual Check

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- \
  agent check sqlserver
```

### Verify Custom Metrics

```bash
kubectl exec -n datadog daemonset/datadog-agent -c agent -- \
  sh -c "agent check sqlserver 2>&1 | grep -i 'sqlserver.order'"
```

You should see:
- `sqlserver.order.count` - Order counts by status (completed, pending, cancelled)
- `sqlserver.order.revenue` - Revenue by status
- `sqlserver.order.pending_count` - Total pending orders

### Test SQL Query Directly

```bash
kubectl exec deployment/sqlserver -- \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U datadog -P 'Password123!' -C \
  -Q "SELECT status, COUNT(*) as order_count, SUM(total_amount) as total_revenue FROM testdb.dbo.orders GROUP BY status"
```

Expected result:
```
status               order_count total_revenue
-------------------- ----------- -------------
cancelled                      1        120.75
completed                      3        650.50
pending                        1         75.25
```

## 📊 Metrics Collected

### Custom Business Metrics

| Metric Name | Type | Description | Tags |
|-------------|------|-------------|------|
| `sqlserver.order.count` | gauge | Number of orders by status | `status:completed/pending/cancelled`, `query:order_stats` |
| `sqlserver.order.revenue` | gauge | Total revenue by status | `status:completed/pending/cancelled`, `query:order_stats` |
| `sqlserver.order.pending_count` | gauge | Total count of pending orders | `query:pending_orders` |

### Standard SQL Server Metrics

The integration also collects 260+ standard metrics including:
- `sqlserver.stats.connections` - Active connections
- `sqlserver.buffer.cache_hit_ratio` - Buffer cache efficiency
- `sqlserver.memory.database_cache` - Database cache memory
- `sqlserver.database.files.size` - Database file sizes
- `sqlserver.tempdb.file_space_usage.*` - TempDB usage
- Many more from `sys.dm_os_performance_counters`

All metrics are tagged with:
- `cluster:sqlserver-lab`
- `env:lab`
- Kubernetes tags (namespace, pod, deployment, etc.)
- Database-specific tags

## 🔧 Configuration Details

### Autodiscovery Annotations v2

The key to this setup is using **Autodiscovery annotations v2** format, which provides a cleaner structure:

```yaml
ad.datadoghq.com/sqlserver.checks: |
  {
    "sqlserver": {
      "init_config": {},
      "instances": [...]
    }
  }
```

### Critical Connection Parameters

For **ODBC Driver 18 for SQL Server** (the only driver available in Datadog Agent), you must include:

```yaml
"driver": "ODBC Driver 18 for SQL Server"
"connection_string": "TrustServerCertificate=yes;Trusted_Connection=no;"
```

**Why these parameters?**
- `TrustServerCertificate=yes` - Required for Driver 18 to accept self-signed certificates
- `Trusted_Connection=no` - Required for SQL authentication (not Windows auth)
- Driver 17 is **NOT** available in the Datadog Agent container

### Custom Query Format

Custom queries follow the Datadog documentation format:

```yaml
"custom_queries": [
  {
    "query": "SELECT column1, column2, column3 FROM table WHERE condition",
    "columns": [
      {"name": "column1_name", "type": "tag"},      # Becomes a tag
      {"name": "metric.name", "type": "gauge"},     # Becomes a gauge metric
      {"name": "metric.count", "type": "rate"}      # Becomes a rate metric
    ],
    "tags": ["query:descriptive_name"]              # Additional tags
  }
]
```

**Column Types:**
- `tag` - Value becomes a tag on the metric
- `gauge` - Absolute value metric
- `rate` - Rate of change metric
- `count` - Monotonic counter

## 🐛 Troubleshooting

### Issue: SSL Certificate Verification Error

**Error:**
```
SSL Provider: [error:0A000086:SSL routines::certificate verify failed:self-signed certificate]
```

**Solution:**
Add to `connection_string`:
```yaml
"connection_string": "TrustServerCertificate=yes;Trusted_Connection=no;"
```

### Issue: Driver Not Found

**Error:**
```
configured odbc driver ODBC Driver 17 for SQL Server not in list of installed drivers
```

**Solution:**
Use ODBC Driver 18 (the only driver in Datadog Agent):
```yaml
"driver": "ODBC Driver 18 for SQL Server"
```

### Issue: Cannot Access Database

**Error:**
```
The server principal "datadog" is not able to access the database "testdb"
```

**Solution:**
Grant database-level permissions:
```sql
USE testdb;
CREATE USER datadog FOR LOGIN datadog;
GRANT SELECT ON SCHEMA::dbo TO datadog;
```

### Issue: Custom Queries Not Running

**Symptoms:**
- Standard metrics work but custom queries don't appear
- No errors in logs

**Checklist:**
1. ✅ Verify datadog user has SELECT permission on tables
2. ✅ Check SQL syntax is valid
3. ✅ Ensure column names match exactly
4. ✅ Test query manually with datadog user
5. ✅ Verify annotations v2 format is correct (valid JSON)
6. ✅ Check pod annotations: `kubectl describe pod -l app=sqlserver`

### Debug Commands

```bash
# Check agent status
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent status

# Run manual check with verbose output
kubectl exec -n datadog daemonset/datadog-agent -c agent -- agent check sqlserver -l debug

# View agent logs
kubectl logs -n datadog daemonset/datadog-agent -c agent --tail=100

# Check SQL Server logs
kubectl logs -l app=sqlserver --tail=50

# Test database connection
kubectl exec deployment/sqlserver -- \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U datadog -P 'Password123!' -C \
  -Q "SELECT @@VERSION"

# View pod annotations
kubectl get pod -l app=sqlserver -o yaml | grep -A 50 "annotations:"
```

## 📚 Database Schema

### testdb.orders Table

```sql
CREATE TABLE orders (
    order_id INT PRIMARY KEY IDENTITY(1,1),
    customer_name VARCHAR(100),
    order_date DATETIME DEFAULT GETDATE(),
    total_amount DECIMAL(10,2),
    status VARCHAR(20)  -- 'completed', 'pending', 'cancelled'
);
```

**Sample Data:**

| order_id | customer_name | order_date | total_amount | status |
|----------|---------------|------------|--------------|---------|
| 1 | Alice Johnson | 2025-10-24 | 150.50 | completed |
| 2 | Bob Smith | 2025-10-24 | 200.00 | completed |
| 3 | Charlie Brown | 2025-10-24 | 75.25 | pending |
| 4 | Diana Prince | 2025-10-24 | 300.00 | completed |
| 5 | Eve Adams | 2025-10-24 | 120.75 | cancelled |

### User Permissions

```sql
-- Server-level permissions
GRANT SELECT on sys.dm_os_performance_counters to datadog;
GRANT VIEW SERVER STATE to datadog;
GRANT VIEW ANY DEFINITION to datadog;

-- Database-level permissions (per database)
USE testdb;
CREATE USER datadog FOR LOGIN datadog;
GRANT SELECT ON SCHEMA::dbo TO datadog;
```

## 🎨 Customizing for Your Use Case

### Adding More Custom Queries

Edit the `custom_queries` array in the annotations:

```yaml
{
  "query": "SELECT region, SUM(sales) as total_sales FROM sales_data GROUP BY region",
  "columns": [
    {"name": "region", "type": "tag"},
    {"name": "sales.total", "type": "gauge"}
  ],
  "tags": ["query:regional_sales"]
}
```

### Changing Collection Interval

Add `min_collection_interval` to instance config:

```yaml
"instances": [
  {
    "host": "%%host%%,1433",
    "min_collection_interval": 30,  # seconds (default: 15)
    ...
  }
]
```

### Adding More Tags

```yaml
"tags": [
  "env:production",
  "team:backend",
  "application:ecommerce",
  "custom:value"
]
```

## 🧹 Cleanup

```bash
# Delete SQL Server
kubectl delete deployment sqlserver
kubectl delete service sqlserver
kubectl delete configmap sqlserver-init

# Uninstall Datadog
helm uninstall datadog-agent -n datadog

# Delete namespace
kubectl delete namespace datadog

# Stop minikube
minikube stop
# OR delete cluster entirely
minikube delete
```

## 🔗 References

- [Datadog SQL Server Integration](https://docs.datadoghq.com/integrations/sqlserver/)
- [Collect SQL Server Custom Metrics](https://docs.datadoghq.com/integrations/guide/collect-sql-server-custom-metrics/)
- [Autodiscovery Annotations v2](https://docs.datadoghq.com/containers/kubernetes/integrations/?tab=kubernetesannotationsv2)
- [SQL Server Troubleshooting](https://docs.datadoghq.com/database_monitoring/setup_sql_server/troubleshooting/)

## 📝 Key Takeaways

✅ **Use Autodiscovery annotations v2** for cleaner configuration  
✅ **ODBC Driver 18** requires `TrustServerCertificate=yes`  
✅ **Trusted_Connection=no** is required for SQL authentication  
✅ **Database permissions** must be granted at both server and database level  
✅ **Custom queries** can collect business metrics from any table  
✅ **Tag by dimensions** (like status) for better metric slicing in Datadog  

---

**Lab Created:** October 24, 2025  
**Cluster:** sqlserver-lab (minikube)  
**Datadog Site:** datadoghq.com  
**SQL Server Version:** 2022 RTM-CU21 (Developer Edition)  
**Datadog Agent Version:** 7.71.2
