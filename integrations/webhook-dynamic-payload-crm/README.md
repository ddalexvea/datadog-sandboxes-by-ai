# Webhook - Double-Serialized JSON with $TEXT_ONLY_MSG

## Context

Reproduces a failure when using Datadog webhook variables (`$EVENT_TITLE`, `$TEXT_ONLY_MSG`) inside a double-serialized JSON payload — when the target CRM API expects `input_data` to be a JSON-encoded string. Two compounding issues prevent the API from accepting the request:

1. **Wrong syntax:** Using monitor template syntax (`{{EVENT_TITLE}}`) in the webhook payload instead of webhook syntax (`$EVENT_TITLE`) — variables are sent as literal text
2. **Multi-line content:** When `$TEXT_ONLY_MSG` contains real newlines (e.g. from `{{log.message}}` with multiline logs), they are inserted raw into the JSON string, producing **Invalid control character** parse errors

## Environment

- **Platform:** Local (Python 3 + curl)
- **Integration:** Webhooks
- **Dependencies:** Python 3.x (no external packages)

## Schema

```mermaid
sequenceDiagram
    participant DD as Datadog Webhook
    participant Sub as Variable Substitution
    participant API as Target CRM API

    DD->>Sub: Payload template with $VARIABLE placeholders
    Sub->>Sub: Raw text replacement (no JSON escaping)
    Sub->>API: POST with substituted payload

    Note over API: Parses outer JSON
    Note over API: Parses inner input_data JSON string

    alt Static payload
        API-->>DD: 200 OK (case created)
    end
    alt Multi-line $TEXT_ONLY_MSG (real newlines)
        API-->>DD: 400 Invalid control character
    end
    alt Single-line or escaped \n
        API-->>DD: 200 OK (case created)
    end
```

## Log Message Formats and CRM Impact

When the monitor uses `{{log.message}}` and the webhook puts `$TEXT_ONLY_MSG` in `input_data`, the log message format determines whether the CRM can parse the JSON:

| Format | Log message content | CRM JSON parse | Notes |
|--------|---------------------|----------------|-------|
| **Multiline** | Real line breaks (U+000A) | Fails | Invalid control characters; CRM rejects |
| **Singleline** | No newlines | OK | Valid JSON |
| **Escaped \n** | Literal `\n` (backslash-n) | OK | Safe; no control chars |

**Fix:** Avoid `{{log.message}}` when logs are multiline. Use attribute placeholders only (`{{log.attributes.applicationNumber}}`, etc.) and flatten the monitor message to one line.

## Quick Start

### 1. Clone and navigate

```bash
git clone https://github.com/ddalexvea/datadog-sandboxes-by-ai.git
cd datadog-sandboxes-by-ai/integrations/webhook-dynamic-payload-crm
```

### 2. Run standalone simulation (no server needed)

```bash
python3 simulate_webhook.py
```

Runs test cases covering static vs dynamic payloads, `{{...}}` vs `$VARIABLE` syntax, and multi-line vs single-line `$TEXT_ONLY_MSG`.

### 3. Run end-to-end with mock CRM server

Terminal 1 — start the mock CRM:

```bash
python3 crm_mock_server.py
```

Terminal 2 — send test payloads:

```bash
# Test 1: Static payload (works)
curl -s -X POST http://127.0.0.1:8899 \
  -H "Content-Type: application/json" \
  -d '{"input_data": "{\"request\":{\"subject\":\"New Ticket\",\"description\":\"Static test\",\"category\":{\"id\":\"303\",\"name\":\"Business Application\"},\"subcategory\":{\"id\":\"610\",\"name\":\"Mfund Application\"},\"item\":{\"id\":\"2401\",\"name\":\"Duplicate\"},\"priority\":{\"id\":\"904\",\"name\":\"1 Low\"},\"urgency\":{\"id\":\"4\",\"name\":\"Low\"},\"impact\":{\"id\":\"4\",\"name\":\"Affects User\"},\"request_type\":{\"id\":\"1\",\"name\":\"Incident\"},\"requester\":{\"email_id\":\"test@example.com\"},\"status\":{\"name\":\"Open\"},\"template\":{\"id\":\"17802\",\"name\":\"Data Dog\"}}}"}'

# Test 2: Dynamic payload with multi-line message (fails — 400)
curl -s -X POST http://127.0.0.1:8899 \
  -H "Content-Type: application/json" \
  -d '{"input_data": "{\"request\":{\"subject\":\"[Triggered] Payment Failure Monitor\",\"description\":\"Payment failure detected\nError: TIMEOUT\nAmount: 5000\",\"category\":{\"id\":\"303\",\"name\":\"Business Application\"},\"subcategory\":{\"id\":\"610\",\"name\":\"Mfund Application\"},\"item\":{\"id\":\"2401\",\"name\":\"Duplicate\"},\"priority\":{\"id\":\"904\",\"name\":\"1 Low\"},\"urgency\":{\"id\":\"4\",\"name\":\"Low\"},\"impact\":{\"id\":\"4\",\"name\":\"Affects User\"},\"request_type\":{\"id\":\"1\",\"name\":\"Incident\"},\"requester\":{\"email_id\":\"test@example.com\"},\"status\":{\"name\":\"Open\"},\"template\":{\"id\":\"17802\",\"name\":\"Data Dog\"}}}"}'

# Test 3: Dynamic payload with single-line message (works — the fix)
curl -s -X POST http://127.0.0.1:8899 \
  -H "Content-Type: application/json" \
  -d '{"input_data": "{\"request\":{\"subject\":\"[Triggered] Payment Failure Monitor\",\"description\":\"Alert: APP-12345 | TxnID: TXN-67890 | Status: FAILED | Amount: 5000.00\",\"category\":{\"id\":\"303\",\"name\":\"Business Application\"},\"subcategory\":{\"id\":\"610\",\"name\":\"Mfund Application\"},\"item\":{\"id\":\"2401\",\"name\":\"Duplicate\"},\"priority\":{\"id\":\"904\",\"name\":\"1 Low\"},\"urgency\":{\"id\":\"4\",\"name\":\"Low\"},\"impact\":{\"id\":\"4\",\"name\":\"Affects User\"},\"request_type\":{\"id\":\"1\",\"name\":\"Incident\"},\"requester\":{\"email_id\":\"test@example.com\"},\"status\":{\"name\":\"Open\"},\"template\":{\"id\":\"17802\",\"name\":\"Data Dog\"}}}"}'
```

## Test Commands

### Standalone simulation

```bash
python3 simulate_webhook.py
```

### Mock server health check

```bash
curl -s http://127.0.0.1:8899/health
```

## Expected vs Actual

| Test Case | Expected | Actual |
|-----------|----------|--------|
| Static payload (no variables) | 200 OK, case created | 200 OK |
| `{{EVENT_TITLE}}` syntax (wrong) | Variables sent as literal text | 200 OK but subject = `{{EVENT_TITLE}}` literally |
| `$EVENT_TITLE` + multi-line `$TEXT_ONLY_MSG` | 400 JSON parse error | 400 `Invalid control character at: line 1 column 174` |
| `$EVENT_TITLE` + single-line `$TEXT_ONLY_MSG` | 200 OK, case created with dynamic data | 200 OK |

### Custom Variable Limitation

Webhook **custom variables** (Integrations > Webhooks > Custom Variables) store **static values** only. If you set `PAYLOAD_MSG` = `{{log.message}}` as a custom variable:

- The webhook sends the literal string `"{{log.message}}"` — no monitor template expansion
- **Fix:** Use the built-in `$TEXT_ONLY_MSG` in the webhook payload. Put `{{log.message}}` or `{{log.attributes.X}}` in the **monitor notification message**; Datadog renders it there, and the result becomes `$TEXT_ONLY_MSG`.

## Fix / Workaround

Two changes required in the Datadog webhook configuration:

**Change 1 — Use correct variable syntax in the webhook payload:**

```json
{
  "input_data": "{\"request\":{\"subject\":\"$EVENT_TITLE\",\"description\":\"$TEXT_ONLY_MSG\",\"category\":{\"id\":\"303\",\"name\":\"Business Application\"},\"subcategory\":{\"id\":\"610\",\"name\":\"Mfund Application\"},\"item\":{\"id\":\"2401\",\"name\":\"Duplicate\"},\"priority\":{\"id\":\"904\",\"name\":\"1 Low\"},\"urgency\":{\"id\":\"4\",\"name\":\"Low\"},\"impact\":{\"id\":\"4\",\"name\":\"Affects User\"},\"request_type\":{\"id\":\"1\",\"name\":\"Incident\"},\"requester\":{\"email_id\":\"requester@example.com\"},\"status\":{\"name\":\"Open\"},\"template\":{\"id\":\"17802\",\"name\":\"Data Dog\"}}}"
}
```

**Change 2 — Flatten the monitor notification message to a single line:**

```
Alert: {{log.attributes.applicationNumber}} | TxnID: {{log.attributes.paymentTxnId}} | Status: {{log.attributes.status}} | Method: {{log.attributes.paymentMethod}} | Amount: {{log.attributes.amount}} | Error: {{log.attributes.errMsg}} | Log: {{log.link}}
```

Both changes are required. The `$VARIABLE` fix alone still fails because multi-line expansion breaks the double-serialized JSON.

## End-to-End API Test (Monitor + Webhook + Logs)

Run a full flow using Datadog API: create webhook integration, create Log monitor, send log, verify webhook.site receives payload with resolved `$TEXT_ONLY_MSG`.

### 1. Webhook.site setup

1. Open [https://webhook.site](https://webhook.site)
2. Copy your unique URL (e.g. `https://webhook.site/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)

### 2. Webhook integration (API)

Create or update the webhook in Datadog:

```bash
# Create webhook (or update URL if name exists)
curl -X POST "https://api.datadoghq.com/api/v1/integration/webhooks/configuration/webhooks" \
  -H "Content-Type: application/json" \
  -H "DD-API-KEY: $DD_API_KEY" \
  -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
  -d '{"name":"webhook-sandbox-test","url":"https://webhook.site/YOUR-UUID"}'

# Update webhook URL (if already exists)
curl -X PUT "https://api.datadoghq.com/api/v1/integration/webhooks/configuration/webhooks/webhook-sandbox-test" \
  -H "Content-Type: application/json" \
  -H "DD-API-KEY: $DD_API_KEY" \
  -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
  -d '{"url":"https://webhook.site/YOUR-UUID"}'
```

### 3. Log monitor (API)

Create a Log monitor with `{{log.attributes.X}}` in the message and `@webhook-webhook-sandbox-test`:

```bash
curl -X POST "https://api.datadoghq.com/api/v1/monitor" \
  -H "Content-Type: application/json" \
  -H "DD-API-KEY: $DD_API_KEY" \
  -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
  -d '{
    "name": "[Webhook Sandbox] Log monitor - DELETE ME",
    "type": "log alert",
    "query": "logs(\"service:webhook-sandbox-test\").rollup(\"count\").last(\"5m\") > 0",
    "message": "Application: {{log.attributes.applicationNumber}} | TxnID: {{log.attributes.paymentTxnId}} | Status: {{log.attributes.status}} | Amount: {{log.attributes.amount}} | Error: {{log.attributes.errMsg}} | Log: {{log.link}}\n\n@webhook-webhook-sandbox-test",
    "options": {"thresholds": {"critical": 0}, "enable_logs_sample": true, "notify_no_data": false}
  }'
```

### 4. Send log (API)

```bash
curl -X POST "https://http-intake.logs.datadoghq.com/v1/input" \
  -H "Content-Type: application/json" \
  -H "DD-API-KEY: $DD_API_KEY" \
  -d '[{
    "service": "webhook-sandbox-test",
    "ddsource": "node",
    "message": "Payment redirect: applicationNumber=APP-12345, paymentTxnId=TXN-67890, status=FAILED",
    "applicationNumber": "APP-12345",
    "paymentTxnId": "TXN-67890",
    "status": "FAILED",
    "amount": "5000.00",
    "errMsg": "Card authentication failed"
  }]'
```

### 5. Run full E2E script

The `api_e2e_test.py` script automates all steps: create webhook, create monitor, send log, wait for evaluation, poll webhook.site, delete monitor.

```bash
export DD_API_KEY="your-api-key"
export DD_APP_KEY="your-app-key"
export WEBHOOK_URL="https://webhook.site/YOUR-UUID"
python3 api_e2e_test.py
```

**Note:** For EU/US1-FED use `api.datadoghq.eu` or `api.us1.datadoghq.com`. Set `DD_SITE=eu1` or `DD_SITE=us1` if using the script.

### 6. Verify webhook content

Check [https://webhook.site/#!/view/YOUR-UUID](https://webhook.site) for incoming POST requests. The payload should contain `$TEXT_ONLY_MSG` with resolved attributes: `Application: APP-12345 | TxnID: TXN-67890 | ...`.

## Troubleshooting

```bash
# Check if mock server is running
curl -s http://127.0.0.1:8899/health

# Check port availability
lsof -i :8899

# Verbose curl output to see HTTP response details
curl -v -X POST http://127.0.0.1:8899 \
  -H "Content-Type: application/json" \
  -d '{"input_data": "{\"request\":{\"subject\":\"test\"}}"}'
```

## Cleanup

```bash
# Stop mock server (Ctrl+C in Terminal 1)
# No other resources to clean up — fully local reproduction
```

## References

- [Datadog Webhooks Integration](https://docs.datadoghq.com/integrations/webhooks/)
- [Datadog Webhook Variables](https://docs.datadoghq.com/integrations/webhooks/#variables)
- [JSON String Escaping (RFC 8259)](https://datatracker.ietf.org/doc/html/rfc8259#section-7)
