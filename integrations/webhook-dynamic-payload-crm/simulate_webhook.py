#!/usr/bin/env python3
"""
Simulate Datadog webhook variable substitution for double-serialized JSON payloads.
Demonstrates why multi-line $TEXT_ONLY_MSG breaks CRM endpoints that parse input_data.
"""

import json
import sys

# --- Customer's monitor notification message (multi-line) ---
MONITOR_MESSAGE_MULTILINE = """Payment failure detected for Card transactions

Error Message: PAYMENT_GATEWAY_TIMEOUT

Failed Card Transaction Alert

Application Number: APP-12345
Payment Transaction ID: TXN-67890
Transaction Number: 100234

Status: FAILED
Payment Method: CREDIT_CARD
Transaction Time (Epoch): 1710000000

Amount: 5000.00

Error Message:
PAYMENT_GATEWAY_TIMEOUT

Requester IP: 10.0.1.42

View Log: https://app.datadoghq.com/logs?query=service:payment"""

# --- Single-line version (fix) ---
MONITOR_MESSAGE_SINGLELINE = "Alert: APP-12345 | TxnID: TXN-67890 | TxnNo: 100234 | Status: FAILED | Method: CREDIT_CARD | Amount: 5000.00 | Error: PAYMENT_GATEWAY_TIMEOUT | IP: 10.0.1.42 | Log: https://app.datadoghq.com/logs?query=service:payment"

EVENT_TITLE = "[Triggered] Payment Failure Monitor on host:payment-service-01"


def simulate_substitution(payload_template: str, event_title: str, text_only_msg: str) -> str:
    """Simulate Datadog's raw text substitution of webhook variables."""
    result = payload_template.replace("$EVENT_TITLE", event_title)
    result = result.replace("$TEXT_ONLY_MSG", text_only_msg)
    return result


def test_payload(label: str, payload_str: str):
    """Try to parse the payload as JSON and report result."""
    print(f"\n{'='*70}")
    print(f"TEST: {label}")
    print(f"{'='*70}")

    try:
        outer = json.loads(payload_str)
        print(f"  Outer JSON parse: OK")

        # Try parsing the inner input_data
        input_data = outer.get("input_data", "")
        inner = json.loads(input_data)
        print(f"  Inner JSON parse (input_data): OK")
        print(f"  Subject: {inner['request']['subject'][:80]}")
        desc = inner['request']['description']
        print(f"  Description length: {len(desc)} chars, lines: {desc.count(chr(10)) + 1}")
        print(f"  RESULT: CRM would ACCEPT this payload")
        return True
    except json.JSONDecodeError as e:
        print(f"  JSON parse ERROR: {e}")
        # Show the problematic area
        pos = e.pos if hasattr(e, 'pos') else 0
        context_start = max(0, pos - 40)
        context_end = min(len(payload_str), pos + 40)
        print(f"  Near position {pos}: ...{repr(payload_str[context_start:context_end])}...")
        print(f"  RESULT: CRM would REJECT this payload (malformed JSON)")
        return False


# =============================================================
# Test 1: Static payload (customer's working version)
# =============================================================
STATIC_PAYLOAD = '{"input_data": "{\\"request\\": {\\"subject\\": \\"New Ticket\\", \\"description\\": \\"Testing out creation of new ticket\\", \\"subcategory\\": {\\"id\\": \\"610\\", \\"name\\": \\"Mfund Application\\"}, \\"category\\": {\\"id\\": \\"303\\", \\"name\\": \\"Business Application\\"}, \\"urgency\\": {\\"id\\": \\"4\\", \\"name\\": \\"Low\\"}, \\"impact\\": {\\"id\\": \\"4\\", \\"name\\": \\"Affects User\\"}, \\"item\\": {\\"id\\": \\"2401\\", \\"name\\": \\"Duplicate\\"}, \\"priority\\": {\\"id\\": \\"904\\", \\"name\\": \\"1 Low\\"}, \\"request_type\\": {\\"id\\": \\"1\\", \\"name\\": \\"Incident\\"}, \\"requester\\": {\\"email_id\\": \\"test@example.com\\"}, \\"status\\": {\\"name\\": \\"Open\\"}, \\"template\\": {\\"name\\": \\"Data Dog\\", \\"id\\": \\"17802\\"}}}"}'

test_payload("1. Static payload (customer's working version)", STATIC_PAYLOAD)


# =============================================================
# Test 2: Customer's broken payload with {{...}} syntax
# These are NOT substituted by Datadog — sent as literal text
# =============================================================
BROKEN_TEMPLATE_LITERAL = '{"input_data": "{\\"request\\":{\\"subject\\":\\"{{EVENT_TITLE}}\\",\\"description\\":\\"{{$EVENT_MSG}}\\",\\"category\\":{\\"id\\":\\"303\\",\\"name\\":\\"Business Application\\"},\\"subcategory\\":{\\"id\\":\\"610\\",\\"name\\":\\"Mfund Application\\"},\\"item\\":{\\"id\\":\\"2401\\",\\"name\\":\\"Duplicate\\"},\\"priority\\":{\\"id\\":\\"904\\",\\"name\\":\\"1 Low\\"},\\"urgency\\":{\\"id\\":\\"4\\",\\"name\\":\\"Low\\"},\\"impact\\":{\\"id\\":\\"4\\",\\"name\\":\\"Affects User\\"},\\"request_type\\":{\\"id\\":\\"1\\",\\"name\\":\\"Incident\\"},\\"requester\\":{\\"email_id\\":\\"{{email}}\\"},\\"status\\":{\\"name\\":\\"Open\\"},\\"template\\":{\\"id\\":\\"17802\\",\\"name\\":\\"Data Dog\\"}}}"}'

test_payload("2. Customer's {{...}} syntax (literal text, not substituted)", BROKEN_TEMPLATE_LITERAL)
print("  NOTE: JSON is technically valid because {{...}} is just literal text.")
print("  CRM receives literal '{{EVENT_TITLE}}' as subject — not useful data.")


# =============================================================
# Test 3: Corrected $VARIABLE syntax + MULTI-LINE message
# This is what breaks the CRM
# =============================================================
CORRECT_SYNTAX_TEMPLATE = '{"input_data": "{\\"request\\":{\\"subject\\":\\"$EVENT_TITLE\\",\\"description\\":\\"$TEXT_ONLY_MSG\\",\\"category\\":{\\"id\\":\\"303\\",\\"name\\":\\"Business Application\\"},\\"subcategory\\":{\\"id\\":\\"610\\",\\"name\\":\\"Mfund Application\\"},\\"item\\":{\\"id\\":\\"2401\\",\\"name\\":\\"Duplicate\\"},\\"priority\\":{\\"id\\":\\"904\\",\\"name\\":\\"1 Low\\"},\\"urgency\\":{\\"id\\":\\"4\\",\\"name\\":\\"Low\\"},\\"impact\\":{\\"id\\":\\"4\\",\\"name\\":\\"Affects User\\"},\\"request_type\\":{\\"id\\":\\"1\\",\\"name\\":\\"Incident\\"},\\"requester\\":{\\"email_id\\":\\"test@example.com\\"},\\"status\\":{\\"name\\":\\"Open\\"},\\"template\\":{\\"id\\":\\"17802\\",\\"name\\":\\"Data Dog\\"}}}"}'

substituted = simulate_substitution(CORRECT_SYNTAX_TEMPLATE, EVENT_TITLE, MONITOR_MESSAGE_MULTILINE)
test_payload("3. Correct $VARIABLE syntax + MULTI-LINE message (BREAKS JSON)", substituted)


# =============================================================
# Test 4: Corrected $VARIABLE syntax + SINGLE-LINE message (THE FIX)
# =============================================================
substituted_fixed = simulate_substitution(CORRECT_SYNTAX_TEMPLATE, EVENT_TITLE, MONITOR_MESSAGE_SINGLELINE)
test_payload("4. Correct $VARIABLE syntax + SINGLE-LINE message (THE FIX)", substituted_fixed)


# =============================================================
# Summary
# =============================================================
print(f"\n{'='*70}")
print("SUMMARY")
print(f"{'='*70}")
print("Test 1 (static):                    PASS - No variables, no breakage")
print("Test 2 ({{...}} syntax):            PASS* - Valid JSON but variables not substituted")
print("Test 3 ($VAR + multi-line):         FAIL - Newlines in $TEXT_ONLY_MSG break JSON")
print("Test 4 ($VAR + single-line):        PASS - The correct fix")
print()
print("ROOT CAUSE CONFIRMED:")
print("  1. Customer used {{...}} syntax → variables not substituted (sent as literals)")
print("  2. Even with correct $VAR syntax, multi-line $TEXT_ONLY_MSG breaks")
print("     the double-serialized JSON (newlines inside a JSON string value)")
print("  3. Fix: Use $VARIABLE syntax AND flatten monitor message to one line")
