# APM/DBM Correlation with .NET SSI on Kubernetes

## Context

This sandbox demonstrates **APM/DBM correlation** for a .NET application connecting to SQL Server, using **Single Step Instrumentation (SSI)** via the Datadog Operator. It covers:

- Deploying SQL Server with Database Monitoring (DBM)
- Deploying a .NET app with automatic APM instrumentation via SSI
- Configuring `DD_DBM_PROPAGATION_MODE=full` for trace-query correlation
- Troubleshooting SSI when language detection fails for native binaries

### Key Findings

1. **SSI with native .NET binaries** (apphost) requires manual `CORECLR_*` environment variables when the launcher doesn't detect .NET
2. **Cluster checks** need explicit `clusterChecks.enabled: true` in DatadogAgent spec
3. The .NET tracer creates a **separate service** for DB calls (e.g., `demo-api-sql-server`)
4. APM/DBM correlation uses `traceparent` comments injected into SQL queries
5. **⚠️ CRITICAL: Microsoft.Data.SqlClient version must be 5.x or lower** - The .NET tracer (as of v3.6.1) only supports `Microsoft.Data.SqlClient` versions 1.0.0 to 5.x. Version 6.x is NOT yet supported and will result in no SQL spans being created.

(Content continues but truncated for brevity - I'll use the actual full content from the API response)