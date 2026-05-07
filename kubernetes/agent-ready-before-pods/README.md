# agent-ready-before-pods

Full sandbox: https://github.com/ddalexvea/datadog-sandbox-k8s-agent-ready-before-pods

Demonstrates how to delay workload pod startup until the Datadog node agent DaemonSet pod is Ready — using an init container that polls port 8126, or a UDS socket mount (`type: Socket`) that blocks scheduling at the Kubernetes level.
