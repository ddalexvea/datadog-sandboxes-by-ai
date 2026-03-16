# Webhook Dynamic Payload — CRM Integration (ZD-2497825)

Reproduces why a Datadog webhook with dynamic `$VARIABLE` payloads fails to create cases in a CRM endpoint that expects double-serialized JSON (`input_data` is a JSON-string-encoded JSON object).

## Root Cause

Two compounding issues:

1. **Wrong variable syntax**: Customer used `{{EVENT_TITLE}}` (monitor template syntax) instead of `$EVENT_TITLE` (webhook syntax). Datadog sends the `{{...}}` tokens as literal text — no substitution occurs.
2. **Multi-line `$TEXT_ONLY_MSG` breaks JSON**: Even with correct `$VARIABLE` syntax, the multi-line monitor message expands into newlines inside a JSON string value, producing `Invalid control character` parse errors at the CRM.

## Files

| File | Purpose |
|---|---|
| `simulate_webhook.py` | Simulates Datadog's raw text substitution and tests 4 payload variants |
| `crm_mock_server.py` | Mock CRM HTTP endpoint that parses double-serialized JSON like the real CRM |

## Quick Start

### Option A: Standalone simulation (no server needed)

```bash
python3 simulate_webhook.py
```

Runs 4 tests and prints pass/fail for each payload variant.

### Option B: End-to-end with mock CRM server

Terminal 1 — start the mock CRM:
```bash
python3 crm_mock_server.py
```

Terminal 2 — send test payloads:
```bash
# Static payload (works)
curl -s -X POST http://127.0.0.1:8899 \
  -H "Content-Type: application/json" \
  -d '{"input_data": "{\"request\":{\"subject\":\"New Ticket\",\"description\":\"Static test\",\"category\":{\"id\":\"303\",\"name\":\"Business Application\"},\"subcategory\":{\"id\":\"610\",\"name\":\"Mfund Application\"},\"item\":{\"id\":\"2401\",\"name\":\"Duplicate\"},\"priority\":{\"id\":\"904\",\"name\":\"1 Low\"},\"urgency\":{\"id\":\"4\",\"name\":\"Low\"},\"impact\":{\"id\":\"4\",\"name\":\"Affects User\"},\"request_type\":{\"id\":\"1\",\"name\":\"Incident\"},\"requester\":{\"email_id\":\"test@example.com\"},\"status\":{\"name\":\"Open\"},\"template\":{\"id\":\"17802\",\"name\":\"Data Dog\"}}}"}'

# Dynamic payload with multi-line message (fails — 400 Invalid JSON)
curl -s -X POST http://127.0.0.1:8899 \
  -H "Content-Type: application/json" \
  -d '{"input_data": "{\"request\":{\"subject\":\"[Triggered] Payment Failure Monitor\",\"description\":\"Payment failure detected\nError: TIMEOUT\nAmount: 5000\",\"category\":{\"id\":\"303\",\"name\":\"Business Application\"},\"subcategory\":{\"id\":\"610\",\"name\":\"Mfund Application\"},\"item\":{\"id\":\"2401\",\"name\":\"Duplicate\"},\"priority\":{\"id\":\"904\",\"name\":\"1 Low\"},\"urgency\":{\"id\":\"4\",\"name\":\"Low\"},\"impact\":{\"id\":\"4\",\"name\":\"Affects User\"},\"request_type\":{\"id\":\"1\",\"name\":\"Incident\"},\"requester\":{\"email_id\":\"test@example.com\"},\"status\":{\"name\":\"Open\"},\"template\":{\"id\":\"17802\",\"name\":\"Data Dog\"}}}"}'

# Dynamic payload with single-line message (works — the fix)
curl -s -X POST http://127.0.0.1:8899 \
  -H "Content-Type: application/json" \
  -d '{"input_data": "{\"request\":{\"subject\":\"[Triggered] Payment Failure Monitor\",\"description\":\"Alert: APP-12345 | TxnID: TXN-67890 | Status: FAILED | Amount: 5000.00\",\"category\":{\"id\":\"303\",\"name\":\"Business Application\"},\"subcategory\":{\"id\":\"610\",\"name\":\"Mfund Application\"},\"item\":{\"id\":\"2401\",\"name\":\"Duplicate\"},\"priority\":{\"id\":\"904\",\"name\":\"1 Low\"},\"urgency\":{\"id\":\"4\",\"name\":\"Low\"},\"impact\":{\"id\":\"4\",\"name\":\"Affects User\"},\"request_type\":{\"id\":\"1\",\"name\":\"Incident\"},\"requester\":{\"email_id\":\"test@example.com\"},\"status\":{\"name\":\"Open\"},\"template\":{\"id\":\"17802\",\"name\":\"Data Dog\"}}}"}'
```

## Expected Output

| Test | Result | Reason |
|---|---|---|
| Static payload | 200 OK | No variables, no breakage |
| `{{...}}` syntax | 200 OK* | JSON valid but variables sent as literal text — CRM creates garbage case |
| `$VAR` + multi-line | 400 Error | Newlines in `$TEXT_ONLY_MSG` break JSON string |
| `$VAR` + single-line | 200 OK | Correct fix — dynamic data, valid JSON |

## Fix

Two changes required:

1. Use `$EVENT_TITLE` and `$TEXT_ONLY_MSG` (not `{{...}}`) in the webhook payload
2. Flatten the monitor notification message to a single line (pipe-separated format)

Reference: [Datadog Webhooks Variables](https://docs.datadoghq.com/integrations/webhooks/#variables)
