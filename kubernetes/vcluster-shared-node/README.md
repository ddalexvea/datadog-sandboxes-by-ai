# Datadog Agent Container Metrics - Shared Node in vcluster

## Context

When running Datadog agents inside vclusters that share the same physical node, the agent cannot access the host kubelet because vcluster ServiceAccount tokens are not recognized by the host kubelet. This results in:
- `401 Unauthorized` errors when accessing kubelet endpoints
- `nil stats` for containers (the original customer issue)
- Missing CPU/memory usage metrics for pods

The root cause is that vclusters have their own API server and issue their own tokens, which the host kubelet does not trust.

**Full documentation available in the original repository:** [datadog-agent-containers-info-shared-node-in-vcluster](https://github.com/ddalexvea/datadog-agent-containers-info-shared-node-in-vcluster)

## Key Topics

- vcluster agent deployment challenges
- Kubelet authentication with vcluster tokens
- 401 Unauthorized errors
- Workaround using host cluster ServiceAccount tokens
- Init container to replace vcluster SA token
