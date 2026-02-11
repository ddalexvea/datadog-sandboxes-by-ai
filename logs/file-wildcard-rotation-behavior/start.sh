#!/bin/bash

# Start the log rotator in the background
/usr/local/bin/log-rotator.sh &

# Start the Datadog Agent in the foreground
exec /bin/entrypoint.sh
