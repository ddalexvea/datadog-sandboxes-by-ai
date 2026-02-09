# OTel Collector Port 4317 Conflict - DDOT vs Open-Source OTel Collector

## Context

This sandbox reproduces an issue where the **Datadog OpenTelemetry Collector (DDOT)** fails to start because port **4317** is already in use by another **open-source OpenTelemetry Collector** running on the same host.

**Full documentation available in the original repository:** [datadog-agent-embedded-otel-collector-port-conflict-with-open-source-otel-collector](https://github.com/ddalexvea/datadog-agent-embedded-otel-collector-port-conflict-with-open-source-otel-collector)

## Key Topics

- DDOT Collector port conflict with open-source OTel Collector
- Port 4317 binding issues
- ddflare extension failure on port 7777
- Core Agent connection refused errors
- Workarounds: Stopping open-source OTel or configuring custom ports
