"""
Sample log payload for webhook API testing.
Provides multiline, singleline, and escaped-n message formats.
"""

import time

# Single-line (CRM-safe)
LOG_MESSAGE_SINGLELINE = (
    "Payment redirect: applicationNumber=APP-12345, paymentTxnId=TXN-67890, "
    "status=FAILED, amount=5000.00, errMsg=Card authentication failed"
)

# Multiline (breaks CRM JSON when used in $TEXT_ONLY_MSG)
LOG_MESSAGE_MULTILINE = """Payment failure detected

Application: APP-12345
TxnID: TXN-67890
Status: FAILED
Amount: 5000.00
Error: Card authentication failed"""

# Escaped \n (CRM-safe)
LOG_MESSAGE_ESCAPED_N = (
    "Payment redirect:\\n  applicationNumber: APP-12345\\n  paymentTxnId: TXN-67890\\n  "
    "status: FAILED\\n  amount: 5000.00"
)

LOG_ATTRIBUTES = {
    "applicationNumber": "APP-12345",
    "paymentTxnId": "TXN-67890",
    "status": "FAILED",
    "amount": "5000.00",
    "errMsg": "Card authentication failed",
    "paymentMethod": "card",
}


def get_log_payload(service: str = "webhook-sandbox-test", message_format: str = "singleline"):
    """Return log payload. message_format: singleline, multiline, escaped_n."""
    messages = {
        "singleline": LOG_MESSAGE_SINGLELINE,
        "multiline": LOG_MESSAGE_MULTILINE,
        "escaped_n": LOG_MESSAGE_ESCAPED_N,
    }
    msg = messages.get(message_format, LOG_MESSAGE_SINGLELINE)
    return {
        "ddsource": "node",
        "service": service,
        "message": msg,
        "timestamp": int(time.time() * 1000),
        **LOG_ATTRIBUTES,
    }
