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
