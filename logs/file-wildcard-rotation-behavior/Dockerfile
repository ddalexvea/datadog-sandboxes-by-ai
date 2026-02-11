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
