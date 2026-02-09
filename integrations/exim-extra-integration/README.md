# Exim Integration - Pipe Command Bug

> **Note:** All manifests and configurations are included inline for easy copy-paste reproduction.

## Context

The **datadog-exim** community integration has a bug where the subprocess command for checking the mail queue fails silently. The integration uses `['exim -bp', '|', 'exiqsumm']` which doesn't work because:

1. `'exim -bp'` is passed as a single string (Python looks for a binary literally named `"exim -bp"`)
2. The pipe `|` is passed as a literal argument, not interpreted as a shell operator

The agent's `get_subprocess_output` returns `returncode: 0` with empty output, making the bug **silent** - the check appears to succeed but no metrics are collected.

> **Known Issue:** This bug is already reported as [GitHub Issue #2209](https://github.com/DataDog/integrations-extras/issues/2209) - open since November 2023 with no fix merged. The original integration author acknowledged the bug but is no longer using Exim.

## Environment

* **Agent Version:** 7.x
* **Platform:** minikube (or any Linux host with Exim)
* **Integration:** datadog-exim 1.0.0 (community integration)

## Quick Start

### 1. Start minikube

```bash
minikube delete --all
minikube start --memory=4096 --cpus=2
```

### 2. Build the exim-with-agent image

```bash
eval $(minikube docker-env)

cat << 'EOF' > /tmp/Dockerfile.exim-agent
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    exim4 curl gnupg apt-transport-https sudo procps \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://keys.datadoghq.com/DATADOG_APT_KEY_CURRENT.public | gpg --dearmor -o /usr/share/keyrings/datadog-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/datadog-archive-keyring.gpg] https://apt.datadoghq.com/ stable 7" > /etc/apt/sources.list.d/datadog.list \
    && apt-get update \
    && apt-get install -y datadog-agent \
    && rm -rf /var/lib/apt/lists/*

RUN cp /etc/datadog-agent/datadog.yaml.example /etc/datadog-agent/datadog.yaml

# Install Exim community integration
RUN /opt/datadog-agent/bin/agent/agent integration install --allow-root -t datadog-exim==1.0.0

# Configure exim check
RUN mkdir -p /etc/datadog-agent/conf.d/exim.d
RUN echo -e "init_config:\ninstances:\n  - exim_command: exim -bp | exiqsumm" > /etc/datadog-agent/conf.d/exim.d/conf.yaml

# Allow dd-agent to run exim commands
RUN usermod -aG Debian-exim dd-agent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 25
CMD ["/entrypoint.sh"]
EOF

cat << 'EOF' > /tmp/entrypoint.sh
#!/bin/bash
set -e
sed -i "s/^# api_key:.*/api_key: ${DD_API_KEY:-testkey123}/" /etc/datadog-agent/datadog.yaml
sed -i "s/^# site:.*/site: ${DD_SITE:-datadoghq.com}/" /etc/datadog-agent/datadog.yaml
sed -i "s/^# hostname:.*/hostname: ${DD_HOSTNAME:-exim-test-host}/" /etc/datadog-agent/datadog.yaml
exim4 -bd -q30m &
echo "Exim started"
exec /opt/datadog-agent/bin/agent/agent run
EOF

cd /tmp && docker build -t exim-with-agent:latest -f Dockerfile.exim-agent .
```

### 3. Deploy resources

```bash
kubectl apply -f - <<'MANIFEST'
---
apiVersion: v1
kind: Namespace
metadata:
  name: exim-test
---
apiVersion: v1
kind: Pod
metadata:
  name: exim-with-agent
  namespace: exim-test
  labels:
    app: exim
spec:
  containers:
  - name: exim-agent
    image: exim-with-agent:latest
    imagePullPolicy: Never
    env:
    - name: DD_API_KEY
      value: "testkey123"
    - name: DD_SITE
      value: "datadoghq.com"
    - name: DD_HOSTNAME
      value: "exim-test-host"
    ports:
    - containerPort: 25
      name: smtp
    securityContext:
      privileged: true
MANIFEST
```

### 4. Wait for ready

```bash
kubectl wait --for=condition=ready pod -l app=exim -n exim-test --timeout=300s
```

### 5. Generate mail queue

```bash
kubectl exec -n exim-test exim-with-agent -- bash -c '
for i in 1 2 3 4 5; do
  echo "Test $i" | exim4 -odq test${i}@nonexistent.invalid 2>/dev/null
done
sleep 1
echo "Queue count: $(exim4 -bpc)"
exim4 -bp | exiqsumm
'
```

## Test Cases

### Case 1: Empty Queue - NO FIX (Bug)

```bash
# Verify queue is empty
kubectl exec -n exim-test exim-with-agent -- exim4 -bpc
# Output: 0

# Run agent check
kubectl exec -n exim-test exim-with-agent -- /opt/datadog-agent/bin/agent/agent check exim
```

**Expected:** `exim.queue.count = 0`  
**Actual:** 0 metrics reported (nothing)

---

### Case 2: Queue with Messages - NO FIX (Bug)

```bash
# Generate 5 messages in queue
kubectl exec -n exim-test exim-with-agent -- bash -c '
for i in 1 2 3 4 5; do
  echo "Test $i" | exim4 -odq test${i}@nonexistent.invalid 2>/dev/null
done'

# Verify queue has messages
kubectl exec -n exim-test exim-with-agent -- exim4 -bpc
# Output: 5

# Verify shell command works
kubectl exec -n exim-test exim-with-agent -- bash -c "exim4 -bp | exiqsumm"
# Output: Count=5, Volume=1565

# Run agent check
kubectl exec -n exim-test exim-with-agent -- /opt/datadog-agent/bin/agent/agent check exim
```

**Expected:** `exim.queue.count = 5`, `exim.queue.volume = 1565`  
**Actual:** 0 metrics reported (nothing)

**Debug output:**
```
Running get_subprocess_output with cmd: ['exim -bp', '|', 'exiqsumm']
get_subprocess_output returned (len(out): 0 ; len(err): 0 ; returncode: 0)
```

---

### Case 3: Empty Queue - WITH FIX

First apply the fix (see Fix Options section), then:

```bash
# Clear queue
kubectl exec -n exim-test exim-with-agent -- bash -c "exim4 -bp | awk '{print \$3}' | xargs -r exim4 -Mrm" 2>/dev/null

# Verify queue is empty
kubectl exec -n exim-test exim-with-agent -- exim4 -bpc
# Output: 0

# Run agent check
kubectl exec -n exim-test exim-with-agent -- /opt/datadog-agent/bin/agent/agent check exim
```

**Expected:** `exim.queue.count = 0`  
**Actual:** `exim.queue.count = 0` ✅

---

### Case 4: Queue with Messages - WITH FIX

```bash
# Generate 5 messages in queue
kubectl exec -n exim-test exim-with-agent -- bash -c '
for i in 1 2 3 4 5; do
  echo "Test $i" | exim4 -odq test${i}@nonexistent.invalid 2>/dev/null
done'

# Verify queue has messages
kubectl exec -n exim-test exim-with-agent -- exim4 -bpc
# Output: 5

# Run agent check
kubectl exec -n exim-test exim-with-agent -- /opt/datadog-agent/bin/agent/agent check exim
```

**Expected:** `exim.queue.count = 5`, `exim.queue.volume = 1565`  
**Actual:** `exim.queue.count = 5`, `exim.queue.volume = 1565` ✅

---

### Summary Table

| Case | Queue | Fix Applied | Expected | Actual |
|------|-------|-------------|----------|--------|
| 1 | Empty (0) | ❌ No | `count = 0` | 0 metrics |
| 2 | 5 messages | ❌ No | `count = 5` | 0 metrics |
| 3 | Empty (0) | ✅ Yes | `count = 0` | `count = 0` ✅ |
| 4 | 5 messages | ✅ Yes | `count = 5` | `count = 5` ✅ |

## Root Cause

In `/opt/datadog-agent/embedded/lib/python3.13/site-packages/datadog_checks/exim/check.py`:

```python
def _get_queue_stats(self):
    command = ['exim -bp', '|', 'exiqsumm']  # BUG: pipe doesn't work!
    output, _, _ = get_subprocess_output(command, self.log, False)
```

**Problem:** `get_subprocess_output` runs without shell interpretation, so:
- `'exim -bp'` → Python looks for binary named `"exim -bp"` (with space)
- `'|'` → Passed as literal argument, not shell pipe
- `'exiqsumm'` → Never receives any input

### Additional Issue: Empty Queue Not Handled

When the queue is empty, the integration should report `count = 0`, not report nothing. This is important for:
- Proving the check is running
- Alerting on `queue.count > 0`
- Continuous metric timelines

## How the Agent Runs Commands

The agent process runs as the `dd-agent` user (configured via systemd service file). Commands executed by checks run under that user's context automatically.

**Note:** The `su -m dd-agent` command you may see in troubleshooting is a **manual test** to verify permissions - it's NOT added by the agent automatically.

```
Agent Process (dd-agent user)
    └── Python Check
        └── get_subprocess_output(['exim', '-bp'])
            └── exec() as dd-agent user (no su wrapping)
```

## Fix Options

### Option 1: Use subprocess.run (Works but not officially supported)

> ⚠️ [Datadog docs](https://docs.datadoghq.com/developers/custom_checks/write_agent_check/#writing-checks-that-run-command-line-programs) say not to use raw `subprocess` module. This fix works in practice but is against best practices.

```bash
kubectl exec -n exim-test exim-with-agent -- bash -c "cat > /opt/datadog-agent/embedded/lib/python3.13/site-packages/datadog_checks/exim/check.py << 'PYEOF'
import re
from collections import namedtuple
import subprocess

from datadog_checks.base import AgentCheck


class EximCheck(AgentCheck):
    __NAMESPACE__ = 'exim'
    SERVICE_CHECK_NAME = 'returns.output'

    def check(self, _):
        tags = self.instance.get('tags', [])
        try:
            queue_stats = self._get_queue_stats()
            for queue in queue_stats:
                self.gauge('queue.count', int(queue.Count), tags=tags + [f'domain:{queue.Domain}'])
                self.gauge('queue.volume', self.parse_size(queue.Volume), tags=tags + [f'domain:{queue.Domain}'])
            self.service_check(self.SERVICE_CHECK_NAME, AgentCheck.OK, tags)
        except Exception as e:
            self.log.info('Cannot get exim queue info: %s', e)
            self.service_check(self.SERVICE_CHECK_NAME, AgentCheck.CRITICAL, tags, message=str(e))

    def _get_queue_stats(self):
        # Use shell=True to properly handle the pipe
        result = subprocess.run('exim -bp | exiqsumm', shell=True, capture_output=True, text=True)
        output = result.stdout

        # Handle empty queue - return 0 instead of nothing
        if not output.strip() or 'TOTAL' not in output:
            Queue = namedtuple('Queue', ['Count', 'Volume', 'Oldest', 'Newest', 'Domain'])
            return [Queue('0', '0B', '0m', '0m', 'none')]

        header = []
        data = []
        for line in filter(None, output.splitlines()):
            if '----' in line:
                continue
            if not header:
                header = line.split()
                queue = namedtuple('Queue', header)
                continue
            line_contents = line.split()
            if line_contents and line_contents[-1] != 'TOTAL':
                data.append(queue(*line_contents))
        return data

    @staticmethod
    def parse_size(size_string):
        match = re.match(r'([0-9]+)([a-z]+)', size_string, re.I)
        if match:
            number, unit = match.groups()
        else:
            number, unit = size_string, 'B'
        units = {'B': 1, 'KB': 10**3, 'MB': 10**6, 'GB': 10**9, 'TB': 10**12}
        return int(float(number) * units.get(unit, 1))
PYEOF"
```

### Option 2: Use exim -bpc (Officially supported, simpler)

This approach uses `get_subprocess_output` correctly but only gets the queue count (no volume/domain breakdown):

```python
from datadog_checks.base import AgentCheck
from datadog_checks.base.utils.subprocess_output import get_subprocess_output

class EximCheck(AgentCheck):
    __NAMESPACE__ = 'exim'
    SERVICE_CHECK_NAME = 'returns.output'

    def check(self, _):
        tags = self.instance.get('tags', [])
        try:
            # exim -bpc returns just the count (integer)
            out, _, _ = get_subprocess_output(['exim', '-bpc'], self.log, False)
            count = int(out.strip()) if out.strip() else 0
            self.gauge('queue.count', count, tags=tags)
            self.service_check(self.SERVICE_CHECK_NAME, AgentCheck.OK, tags)
        except Exception as e:
            self.log.info('Cannot get exim queue info: %s', e)
            self.service_check(self.SERVICE_CHECK_NAME, AgentCheck.CRITICAL, tags, message=str(e))
```

### Verify fix

See **Case 3** and **Case 4** in the Test Cases section above.

## Python Pipe Demo

To understand the bug, run this demo inside the container:

```bash
kubectl exec -n exim-test exim-with-agent -- /opt/datadog-agent/embedded/bin/python3 -c "
import subprocess

print('=' * 60)
print('BROKEN: subprocess without shell=True')
print('=' * 60)
print('Command: [\"exim -bp\", \"|\", \"exiqsumm\"]')
try:
    result = subprocess.run(['exim -bp', '|', 'exiqsumm'], capture_output=True, text=True)
    print(f'stdout: {repr(result.stdout)}')
except FileNotFoundError as e:
    print(f'ERROR: {e}')

print()
print('=' * 60)
print('WORKING: subprocess with shell=True')
print('=' * 60)
print('Command: \"exim -bp | exiqsumm\"')
result = subprocess.run('exim -bp | exiqsumm', shell=True, capture_output=True, text=True)
print(f'stdout length: {len(result.stdout)} chars')
print(result.stdout)
"
```

### Expected Output

```
============================================================
BROKEN: subprocess without shell=True
============================================================
Command: ["exim -bp", "|", "exiqsumm"]
ERROR: [Errno 2] No such file or directory: 'exim -bp'

============================================================
WORKING: subprocess with shell=True
============================================================
Command: "exim -bp | exiqsumm"
stdout length: 231 chars

Count  Volume  Oldest  Newest  Domain
-----  ------  ------  ------  ------

    5    1565      5m      5m  nonexistent.invalid
---------------------------------------------------------------
    5    1565      5m      5m  TOTAL
```

**Key insight:** The `|` character is **only a pipe when interpreted by a shell**. Without `shell=True`, Python treats it as a literal string argument.

## Troubleshooting

```bash
# Pod logs
kubectl logs -n exim-test exim-with-agent --tail=100

# Check queue directly
kubectl exec -n exim-test exim-with-agent -- exim4 -bpc

# Agent status
kubectl exec -n exim-test exim-with-agent -- /opt/datadog-agent/bin/agent/agent status

# View check.py source
kubectl exec -n exim-test exim-with-agent -- cat /opt/datadog-agent/embedded/lib/python3.13/site-packages/datadog_checks/exim/check.py
```

## Cleanup

```bash
kubectl delete namespace exim-test
minikube delete
```

## References

* [GitHub Issue #2209 - Exim integration gives no metric data](https://github.com/DataDog/integrations-extras/issues/2209) - **Open since Nov 2023**
* [Datadog Integrations Extras - Exim](https://github.com/DataDog/integrations-extras/tree/master/exim)
* [Writing checks that run command-line programs](https://docs.datadoghq.com/developers/custom_checks/write_agent_check/#writing-checks-that-run-command-line-programs)
* [Python subprocess documentation](https://docs.python.org/3/library/subprocess.html)
