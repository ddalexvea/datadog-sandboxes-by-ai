# APM/DBM Correlation with .NET SSI on Kubernetes

## Context

This sandbox demonstrates **APM/DBM correlation** for a .NET application connecting to SQL Server, using **Single Step Instrumentation (SSI)** via the Datadog Operator. It covers:

- Deploying SQL Server with Database Monitoring (DBM)
- Deploying a .NET app with automatic APM instrumentation via SSI
- Configuring `DD_DBM_PROPAGATION_MODE=full` for trace-query correlation
- Troubleshooting SSI when language detection fails for native binaries

**Full documentation available in the original repository:** [datadog-agent-sqlserver-dotnet-ssi-correlation](https://github.com/ddalexvea/datadog-agent-sqlserver-dotnet-ssi-correlation)

## Key Topics

- SQL Server DBM setup
- .NET Single Step Instrumentation (SSI)
- APM/DBM correlation configuration
- Microsoft.Data.SqlClient version compatibility (5.x only)
- Troubleshooting missing SQL spans
