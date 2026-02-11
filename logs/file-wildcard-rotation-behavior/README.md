# Log File Wildcard Rotation Behavior

**Note:** All configurations are included inline in this README for easy copy-paste reproduction.

## Context

This sandbox demonstrates how the Datadog Agent handles log file rotation when using wildcard paths (e.g., `app-*.log`). It tests the interaction between `file_wildcard_selection_mode: by_modification_time` and `open_files_limit` to prove whether old rotated files are automatically dropped from tailing.

**Critical Finding:** `file_wildcard_selection_mode: by_modification_time` alone **DOES NOT** drop old files. You must also set `open_files_limit` to force the agent to stop tailing old rotated logs.

## Environment

- **Agent Version:** 7.60.0
- **Platform:** Docker / docker-compose
- **Test:** Automated log rotation every 60 seconds

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

### 1. Create Directory Structure

```bash
mkdir -p file-wildcard-rotation-demo/{conf.d,logs,agent-logs}
cd file-wildcard-rotation-demo
```

### 2. Create Dockerfile

```dockerfile
FROM datadog/agent:7.60.0

# Install necessary tools
RUN apt-get update && apt-get install -y \
    procps \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Create log directory
RUN mkdir -p /var/log/app

# Copy configuration files
COPY datadog.yaml /etc/datadog-agent/datadog.yaml
COPY conf.d/app_logs.yaml /etc/datadog-agent/conf.d/app_logs.d/conf.yaml
COPY log-rotator.sh /usr/local/bin/log-rotator.sh
RUN chmod +x /usr/local/bin/log-rotator.sh

# Set environment variables
ENV DD_API_KEY=dummy_key_for_testing
ENV DD_SITE=datadoghq.com
ENV DD_LOGS_ENABLED=true
ENV DD_LOG_LEVEL=debug

# Start script that runs both agent and log rotator
COPY start.sh /start.sh
RUN chmod +x /start.sh

CMD ["/start.sh"]
```

### 3. Create docker-compose.yml

```yaml
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
      - DD_LOGS_CONFIG_CONTAINER_COLLECT_ALL=false
    volumes:
      - ./logs:/var/log/app
      - ./agent-logs:/var/log/datadog
    stdin_open: true
    tty: true
```

### 4. Create start.sh

```bash
#!/bin/bash

# Start the log rotator in the background
/usr/local/bin/log-rotator.sh &

# Start the Datadog Agent in the foreground
exec /bin/entrypoint.sh
```

### 5. Create log-rotator.sh

```bash
#!/bin/bash

LOG_DIR="/var/log/app"
FILE_COUNTER=1

echo "LOG ROTATION DEMO STARTED"
echo "New log file every 60 seconds"
echo ""

# Function to create and write to a log file
create_and_write_log() {
    local filename="app-$(date +%Y%m%d-%H%M%S).log"
    local filepath="${LOG_DIR}/${filename}"
    
    echo "[$(date '+%H:%M:%S')] ROTATION #${FILE_COUNTER}"
    echo "Creating: ${filename}"
    
    # Write logs for 60 seconds
    local end_time=$(($(date +%s) + 60))
    local line_counter=1
    
    while [ $(date +%s) -lt ${end_time} ]; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "${timestamp} INFO [file=${filename}] Log line #${line_counter}" >> "${filepath}"
        line_counter=$((line_counter + 1))
        sleep 1
    done
    
    echo "Finished writing to ${filename}: ${line_counter} lines"
    echo ""
    FILE_COUNTER=$((FILE_COUNTER + 1))
}

# Wait for agent to start
sleep 15

echo "Starting log rotation cycle..."

# Run forever
while true; do
    create_and_write_log
    echo "ROTATING LOG FILE - Agent should detect new file within 5 seconds"
    sleep 2
done
```

### 6. Create conf.d/app_logs.yaml

```yaml
logs:
  - type: file
    path: /var/log/app/app-*.log
    service: demo-app
    source: custom
    sourcecategory: application
    start_position: end
```

## Test Case 1: With `open_files_limit: 1`

### Create datadog.yaml (Case 1)

```yaml
api_key: dummy_key_for_testing
site: datadoghq.com
hostname: rotation-demo-host

logs_enabled: true
log_level: debug

logs_config:
  file_wildcard_selection_mode: by_modification_time
  open_files_limit: 1  # FORCE LIMIT
  file_scan_period: 5.0
  auditor_ttl: 1

process_config:
  enabled: false

apm_config:
  enabled: false
```

### Run Test Case 1

```bash
docker-compose up --build
```

### Expected Behavior (Case 1)

In another terminal, watch the agent logs:

```bash
docker exec -it datadog-rotation-demo tail -f /var/log/datadog/agent.log | grep -E "After stopping tailers|Starting a new tailer|Closed"
```

**Result:** ✅ Old files ARE dropped

```
After stopping tailers, there are 0 tailers running.  ← OLD TAILER STOPPED
Starting a new tailer for: /var/log/app/app-20260211-145731.log
Closed /var/log/app/app-20260211-145629.log  ← OLD FILE CLOSED
```

## Test Case 2: With Default `open_files_limit: 500`

### Stop Current Test

```bash
docker-compose down
```

### Create datadog.yaml (Case 2)

```yaml
api_key: dummy_key_for_testing
site: datadoghq.com
hostname: rotation-demo-host

logs_enabled: true
log_level: debug

logs_config:
  file_wildcard_selection_mode: by_modification_time
  # NO open_files_limit - uses default 500
  file_scan_period: 5.0
  auditor_ttl: 1

process_config:
  enabled: false

apm_config:
  enabled: false
```

### Run Test Case 2

```bash
docker-compose up --build
```

### Expected Behavior (Case 2)

Watch tailer counts:

```bash
docker exec -it datadog-rotation-demo tail -f /var/log/datadog/agent.log | grep "tailers running. Limit"
```

**Result:** ❌ Old files are NOT dropped

```
After starting new tailers, there are 3 tailers running. Limit is 500.
After starting new tailers, there are 4 tailers running. Limit is 500.  ← ROTATION #1
After starting new tailers, there are 5 tailers running. Limit is 500.  ← ROTATION #2
After starting new tailers, there are 6 tailers running. Limit is 500.  ← ROTATION #3
```

The agent keeps adding tailers and never drops old ones!

## Test Commands

### Agent Status

```bash
# Check agent logs
docker exec -it datadog-rotation-demo tail -f /var/log/datadog/agent.log

# Count active tailers
docker exec -it datadog-rotation-demo tail -f /var/log/datadog/agent.log | grep "tailers running"

# See tailer start/stop events
docker exec -it datadog-rotation-demo tail -f /var/log/datadog/agent.log | grep -E "Starting a new tailer|stop all tailers|Closed"

# Check registry
docker exec -it datadog-rotation-demo cat /opt/datadog-agent/run/registry.json | jq
```

### Log Files

```bash
# List generated log files
ls -lht logs/

# Count log files
ls logs/*.log | wc -l

# Check file sizes
du -h logs/
```

## Expected vs Actual

| Configuration | Expected Old Files Behavior | Actual |
|--------------|----------------------------|--------|
| `by_modification_time` only | ❌ Assumes drops old files | ❌ Keeps ALL files until limit |
| `by_modification_time` + `open_files_limit: 1` | ✅ Drops old files | ✅ Drops old files immediately |
| `by_modification_time` + `open_files_limit: 10` | ✅ Keeps 10 newest | ✅ Keeps 10 newest |

### Screenshots - Case 1 (open_files_limit: 1)

```
[14:57:31] 📝 ROTATION #2
After stopping tailers, there are 0 tailers running.
Starting a new tailer for: /var/log/app/app-20260211-145731.log
Closed /var/log/app/app-20260211-145629.log read 5491 bytes and 60 lines
```

### Screenshots - Case 2 (default limit: 500)

```
[15:00:08] 📝 ROTATION #1
After starting new tailers, there are 4 tailers running. Limit is 500.

[15:01:10] 📝 ROTATION #2  
After starting new tailers, there are 5 tailers running. Limit is 500.
```

## Fix / Workaround

**Problem:** Customer complains about too many old rotated logs being tailed, causing high resource usage.

**Incorrect Solution (doesn't work):**
```yaml
logs_config:
  file_wildcard_selection_mode: by_modification_time  # NOT ENOUGH!
```

**Correct Solution:**
```yaml
logs_config:
  file_wildcard_selection_mode: by_modification_time
  open_files_limit: 10  # Adjust based on actual active logs
  auditor_ttl: 6  # Clean up registry faster
```

This ensures:
- Only the 10 most recent log files are actively tailed
- Older rotated logs are automatically dropped
- Registry entries cleaned up after 6 hours instead of 23

## Troubleshooting

### Agent Not Dropping Old Files

**Symptom:** Tailer count keeps increasing

**Cause:** No `open_files_limit` set (defaults to 500)

**Fix:** Set `open_files_limit` to reasonable number

### Agent Dropping Active Files

**Symptom:** Recently active files being dropped

**Cause:** `open_files_limit` too low

**Fix:** Increase `open_files_limit` or reduce number of active log files

### Check Current Configuration

```bash
docker exec -it datadog-rotation-demo cat /etc/datadog-agent/datadog.yaml
```

## Cleanup

```bash
docker-compose down
rm -rf logs/ agent-logs/
```

## References

- [Datadog Agent Configuration](https://docs.datadoghq.com/agent/configuration/)
- [Log Collection Configuration](https://docs.datadoghq.com/agent/logs/)
- [Agent Docker Tags](https://hub.docker.com/r/datadog/agent/tags)
- [file_wildcard_selection_mode Documentation](https://docs.datadoghq.com/agent/logs/advanced_log_collection/)
