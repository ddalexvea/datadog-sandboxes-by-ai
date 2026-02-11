# Log File Wildcard Rotation - How open_files_limit Works

**Note:** All configurations are included inline in this README for easy copy-paste reproduction.

## Context

This sandbox demonstrates how the Datadog Agent handles log file rotation when using wildcard paths (e.g., `app-*.log`). It proves the interaction between `file_wildcard_selection_mode: by_modification_time` and `open_files_limit`.

**Critical Finding:** `file_wildcard_selection_mode: by_modification_time` alone **DOES NOT** drop old files. You must also set `open_files_limit` to force the agent to stop tailing old rotated logs.

## Environment

- **Agent Version:** 7.60.0
- **Platform:** Docker / docker-compose
- **Test:** Automated log rotation every 60 seconds

**Commands to get versions:**
```bash
docker exec -it datadog-rotation-demo agent version
```

## Schema

```mermaid
graph LR
    A[Log Rotator Script] -->|Every 60s| B[Create New Log File]
    B --> C[app-TIMESTAMP.log]
    D[Datadog Agent] -->|Scans every 5s| E[/var/log/app/app-*.log]
    E --> F{open_files_limit reached?}
    F -->|Yes| G[Stop old tailers]
    F -->|No| H[Keep all tailers active]
    G --> I[Tail only newest files]
    H --> J[Tail ALL matching files]
```

## Quick Start

### 1. Create Directory and Files

```bash
mkdir -p file-wildcard-rotation-demo/{conf.d,logs,agent-logs}
cd file-wildcard-rotation-demo
```

### 2. Create Dockerfile

```bash
cat > Dockerfile <<'EOF'
FROM datadog/agent:7.60.0

RUN apt-get update && apt-get install -y procps vim && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /var/log/app

COPY datadog.yaml /etc/datadog-agent/datadog.yaml
COPY conf.d/app_logs.yaml /etc/datadog-agent/conf.d/app_logs.d/conf.yaml
COPY log-rotator.sh /usr/local/bin/log-rotator.sh
RUN chmod +x /usr/local/bin/log-rotator.sh

ENV DD_API_KEY=dummy_key_for_testing
ENV DD_SITE=datadoghq.com
ENV DD_LOGS_ENABLED=true
ENV DD_LOG_LEVEL=debug

COPY start.sh /start.sh
RUN chmod +x /start.sh

CMD ["/start.sh"]
EOF
```

### 3. Create docker-compose.yml

```bash
cat > docker-compose.yml <<'EOF'
version: '3.8'

services:
  datadog-agent:
    build: .
    container_name: datadog-rotation-demo
    environment:
      - DD_API_KEY=dummy_key_for_testing
      - DD_SITE=datadoghq.com
      - DD_LOGS_ENABLED=true
      - DD_LOG_LEVEL=debug
    volumes:
      - ./logs:/var/log/app
      - ./agent-logs:/var/log/datadog
    stdin_open: true
    tty: true
EOF
```

### 4. Create start.sh

```bash
cat > start.sh <<'EOF'
#!/bin/bash
/usr/local/bin/log-rotator.sh &
exec /bin/entrypoint.sh
EOF
chmod +x start.sh
```

### 5. Create log-rotator.sh

```bash
cat > log-rotator.sh <<'EOF'
#!/bin/bash
LOG_DIR="/var/log/app"
FILE_COUNTER=1

echo "LOG ROTATION DEMO STARTED"
echo "New log file every 60 seconds"

create_and_write_log() {
    local filename="app-$(date +%Y%m%d-%H%M%S).log"
    local filepath="${LOG_DIR}/${filename}"
    
    echo "[$(date '+%H:%M:%S')] ROTATION #${FILE_COUNTER}: ${filename}"
    
    local end_time=$(($(date +%s) + 60))
    local line_counter=1
    
    while [ $(date +%s) -lt ${end_time} ]; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "${timestamp} INFO [file=${filename}] Log line #${line_counter}" >> "${filepath}"
        line_counter=$((line_counter + 1))
        sleep 1
    done
    
    echo "Finished: ${filename} (${line_counter} lines)"
    FILE_COUNTER=$((FILE_COUNTER + 1))
}

sleep 15
echo "Starting log rotation cycle..."

while true; do
    create_and_write_log
    echo "ROTATING - New file in 2 seconds..."
    sleep 2
done
EOF
chmod +x log-rotator.sh
```

### 6. Create conf.d/app_logs.yaml

```bash
mkdir -p conf.d
cat > conf.d/app_logs.yaml <<'EOF'
logs:
  - type: file
    path: /var/log/app/app-*.log
    service: demo-app
    source: custom
    sourcecategory: application
    start_position: end
EOF
```

## Test Case 1: With `open_files_limit: 1`

### Create datadog.yaml (Case 1)

```bash
cat > datadog.yaml <<'EOF'
api_key: dummy_key_for_testing
site: datadoghq.com
hostname: rotation-demo-host

logs_enabled: true
log_level: debug

logs_config:
  file_wildcard_selection_mode: by_modification_time
  open_files_limit: 1  # FORCE LIMIT - only 1 file at a time
  file_scan_period: 5.0
  auditor_ttl: 1

process_config:
  enabled: false
apm_config:
  enabled: false
EOF
```

### Run Test Case 1

```bash
docker-compose up --build
```

### Wait for ready

```bash
# Wait 20 seconds for agent startup and first rotation
sleep 20
```

## Test Commands

### Watch tailer behavior (Case 1)

```bash
# In another terminal
docker exec -it datadog-rotation-demo tail -f /var/log/datadog/agent.log | grep -E "After stopping tailers|Starting a new tailer|Closed"
```

### Expected Output (Case 1)

```
After stopping tailers, there are 0 tailers running.  ← OLD TAILER STOPPED!
Starting a new tailer for: /var/log/app/app-20260211-145731.log
Closed /var/log/app/app-20260211-145629.log  ← OLD FILE CLOSED!
```

### Count tailers

```bash
docker exec -it datadog-rotation-demo tail -f /var/log/datadog/agent.log | grep "tailers running. Limit"
```

### Check registry

```bash
docker exec -it datadog-rotation-demo cat /opt/datadog-agent/run/registry.json | jq
```

### List log files

```bash
ls -lht logs/
```

## Test Case 2: With Default `open_files_limit: 500`

### Stop current container

```bash
docker-compose down
```

### Create datadog.yaml (Case 2)

```bash
cat > datadog.yaml <<'EOF'
api_key: dummy_key_for_testing
site: datadoghq.com
hostname: rotation-demo-host

logs_enabled: true
log_level: debug

logs_config:
  file_wildcard_selection_mode: by_modification_time
  # NO open_files_limit set - uses default 500
  file_scan_period: 5.0
  auditor_ttl: 1

process_config:
  enabled: false
apm_config:
  enabled: false
EOF
```

### Run Test Case 2

```bash
docker-compose up --build
```

### Watch tailer count increase

```bash
docker exec -it datadog-rotation-demo tail -f /var/log/datadog/agent.log | grep "tailers running. Limit"
```

### Expected Output (Case 2)

```
After starting new tailers, there are 3 tailers running. Limit is 500.
After starting new tailers, there are 4 tailers running. Limit is 500.  ← ROTATION #1
After starting new tailers, there are 5 tailers running. Limit is 500.  ← ROTATION #2
After starting new tailers, there are 6 tailers running. Limit is 500.  ← ROTATION #3
```

The agent **never drops old files** - it keeps all of them!

## Expected vs Actual

| Configuration | Expected | Actual |
|--------------|----------|--------|
| `by_modification_time` only | ❌ Drops old files? | ❌ Keeps ALL files until limit 500 |
| `by_modification_time` + `open_files_limit: 1` | ✅ Drops old files | ✅ Drops immediately |
| `by_modification_time` + `open_files_limit: 10` | ✅ Keeps 10 newest | ✅ Keeps 10 newest |

### Screenshots - Test Case 1 (limit: 1)

```
[14:57:31] ROTATION #2: app-20260211-145731.log
After stopping tailers, there are 0 tailers running.
Starting a new tailer for: /var/log/app/app-20260211-145731.log
Closed /var/log/app/app-20260211-145629.log read 5491 bytes and 60 lines
```

### Screenshots - Test Case 2 (default: 500)

```
[15:00:08] ROTATION #1: app-20260211-150008.log
After starting new tailers, there are 4 tailers running. Limit is 500.

[15:01:10] ROTATION #2: app-20260211-150110.log
After starting new tailers, there are 5 tailers running. Limit is 500.
```

## Fix / Workaround

**Problem:** Customer complains about too many old rotated logs being tailed, causing high CPU/memory/disk I/O.

**Incorrect Solution:**
```yaml
logs_config:
  file_wildcard_selection_mode: by_modification_time  # NOT ENOUGH!
```

**Correct Solution:**
```yaml
logs_config:
  file_wildcard_selection_mode: by_modification_time
  open_files_limit: 10  # Adjust based on active logs needed
  auditor_ttl: 6  # Clean up registry faster (hours)
```

This ensures:
- Only the 10 most recent log files are actively tailed
- Older rotated logs are automatically dropped from tailing
- Registry entries cleaned up after 6 hours instead of 23h

## Troubleshooting

### Agent not dropping old files

```bash
# Check current limit
docker exec -it datadog-rotation-demo grep open_files_limit /etc/datadog-agent/datadog.yaml

# Check tailer count over time
docker exec -it datadog-rotation-demo tail -f /var/log/datadog/agent.log | grep "tailers running"
```

**Cause:** No `open_files_limit` set (defaults to 500)

**Fix:** Set `open_files_limit` to reasonable number

### Check agent configuration

```bash
docker exec -it datadog-rotation-demo agent config | grep -A5 logs_config
```

### Check agent status

```bash
docker exec -it datadog-rotation-demo agent status
```

## Cleanup

```bash
docker-compose down
cd ..
rm -rf file-wildcard-rotation-demo
```

## References

- [Datadog Log Collection Configuration](https://docs.datadoghq.com/agent/logs/)
- [Advanced Log Collection](https://docs.datadoghq.com/agent/logs/advanced_log_collection/)
- [Agent Configuration](https://docs.datadoghq.com/agent/configuration/)
- [Agent Docker Tags](https://hub.docker.com/r/datadog/agent/tags)
