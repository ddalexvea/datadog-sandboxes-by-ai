# Datadog Sandboxes Repository

This repository contains sandbox environments for reproducing and demonstrating various Datadog Agent configurations, integrations, and issues.

## Sandbox Index

### Integrations

#### [Airflow StatsD Integration](./integrations/airflow-statsd/)
- **Context:** Collecting Airflow metrics via StatsD to DogStatsD in Kubernetes
- **Key Topics:** Configuration precedence, env vars vs airflow.cfg, Kubernetes service discovery
- **Agent Version:** 7.74.1
- **Platform:** minikube / AKS
- **Original Repo:** [datadog-agent-airflow-statsd](https://github.com/ddalexvea/datadog-agent-airflow-statsd)

#### [Exim Mail Queue Integration](./integrations/exim-extra-integration/)
- **Context:** Exim integration pipe command bug - subprocess fails silently
- **Key Topics:** Python subprocess pipe handling, community integration bug
- **Agent Version:** 7.x
- **Platform:** minikube / Linux
- **Original Repo:** [datadog-agent-exim-extra-integration](https://github.com/ddalexvea/datadog-agent-exim-extra-integration)
- **Related Issue:** [GitHub Issue #2209](https://github.com/DataDog/integrations-extras/issues/2209)

### APM

#### [SQL Server .NET SSI Correlation](./apm/sqlserver-dotnet-ssi-correlation/)
- **Context:** APM/DBM correlation for .NET apps with SQL Server using Single Step Instrumentation
- **Key Topics:** SSI with native binaries, CORECLR env vars, Microsoft.Data.SqlClient 5.x compatibility
- **Agent Version:** 7.x with Operator 1.10.0+
- **Platform:** minikube / Kubernetes
- **Original Repo:** [datadog-agent-sqlserver-dotnet-ssi-correlation](https://github.com/ddalexvea/datadog-agent-sqlserver-dotnet-ssi-correlation)

### AWS

#### [ECS on EC2 Deployment Patterns](./aws/ecs-on-ec2-sandbox/)
- **Context:** Agent deployment strategies for AWS EC2/ECS (Daemon, Sidecar, Cluster Checks, Agentless)
- **Key Topics:** Daemon vs Sidecar, ECS Fargate, EKS Fargate auto-injection
- **Agent Version:** 7.52.0+
- **Platform:** ECS on EC2 / ECS Fargate / EKS
- **Original Repo:** [datadog-agent-ecs-on-ec2-sandbox](https://github.com/ddalexvea/datadog-agent-ecs-on-ec2-sandbox)

### OpenTelemetry

#### [OTel Collector Port Conflict](./otel/embedded-collector-port-conflict/)
- **Context:** DDOT Collector fails when port 4317 is occupied by open-source OTel Collector
- **Key Topics:** Port binding conflicts, ddflare extension failure
- **Agent Version:** 7.75.0
- **Platform:** minikube / Red Hat Linux
- **Original Repo:** [datadog-agent-embedded-otel-collector-port-conflict-with-open-source-otel-collector](https://github.com/ddalexvea/datadog-agent-embedded-otel-collector-port-conflict-with-open-source-otel-collector)

### Kubernetes

#### [vcluster Shared Node Issues](./kubernetes/vcluster-shared-node/)
- **Context:** Agent kubelet access issues when running in vclusters sharing physical nodes
- **Key Topics:** vcluster SA token authentication, 401 Unauthorized errors, workaround with host tokens
- **Agent Version:** 7.74.0
- **Platform:** minikube with vcluster
- **Original Repo:** [datadog-agent-containers-info-shared-node-in-vcluster](https://github.com/ddalexvea/datadog-agent-containers-info-shared-node-in-vcluster)

### Bugs

#### [Container Log Exclusion Bug (Image-Based Filtering)](./bugs/container-log-exclusion-second-case/)
- **Context:** `container_exclude_logs` ignored when using image-based `container_include` patterns
- **Key Topics:** Agent regression in 7.69.0-7.72.x, fixed in 7.73.2+
- **Affected Versions:** 7.69.0 - 7.72.x
- **Fixed In:** 7.73.2+
- **Platform:** minikube / Kubernetes
- **Original Repo:** [datadog-bug-container-log-exclusion-second-case](https://github.com/ddalexvea/datadog-bug-container-log-exclusion-second-case)
- **Fix PR:** [DataDog/datadog-agent#42647](https://github.com/DataDog/datadog-agent/pull/42647)

## Structure

Each sandbox directory contains:
- `README.md` - Summary and link to the full sandbox repository
- (Optional) Supporting files like manifests, scripts, or configurations

## Full Documentation

For complete documentation, step-by-step reproduction instructions, and all manifests, please visit the individual repository links provided above.

## Related Resources

- **Diagnostic Rules Repository:** [datadog-cursor-diagnose-rules](https://github.com/ddalexvea/datadog-cursor-diagnose-rules)
- **Sandbox Template:** [datadog-sandbox-readme-template](https://github.com/ddalexvea/datadog-sandbox-readme-template)

## Contributing

This repository serves as an index. To add a new sandbox:

1. Create a dedicated repository for your sandbox (following the template)
2. Add a summary entry here with a link to the full repo
3. Organize by category (integrations, apm, aws, kubernetes, bugs, etc.)

---

**Maintained by:** Alexandre VEA (Datadog Support)
