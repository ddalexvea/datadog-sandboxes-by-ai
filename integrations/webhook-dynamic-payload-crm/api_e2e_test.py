#!/usr/bin/env python3
"""
End-to-end API test: create webhook, create Log monitor, send log, verify webhook.site.

Usage:
  1. Open https://webhook.site and copy your unique URL
  2. export DD_API_KEY=... DD_APP_KEY=... WEBHOOK_URL="https://webhook.site/YOUR-UUID"
  3. python api_e2e_test.py
"""

import os
import re
import sys
import time
import json
import urllib.request
import urllib.error

DD_API_KEY = os.environ.get("DD_API_KEY")
DD_APP_KEY = os.environ.get("DD_APP_KEY")
WEBHOOK_URL = os.environ.get("WEBHOOK_URL")
DD_SITE = os.environ.get("DD_SITE", "datadoghq.com")
if DD_SITE in ("us1", "us3", "us5", "eu1", "ap1", "ap2"):
    DD_SITE = f"{DD_SITE}.datadoghq.com"
if DD_SITE.startswith("eu1"):
    API_HOST, INTAKE_HOST = "https://api.datadoghq.eu", "https://http-intake.logs.datadoghq.eu"
else:
    API_HOST = f"https://api.{DD_SITE}"
    INTAKE_HOST = f"https://http-intake.logs.{DD_SITE}"
WEBHOOK_NAME = "webhook-sandbox-test"


def api(method, path, data=None):
    url = f"{API_HOST}{path}"
    headers = {
        "Content-Type": "application/json",
        "DD-API-KEY": DD_API_KEY,
        "DD-APPLICATION-KEY": DD_APP_KEY,
    }
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode()) if r.headers.get("content-length") else {}


# --- 1. Webhook integration (create or update) ---

def create_webhook():
    """Create webhook integration. If exists, update URL."""
    try:
        api("POST", "/api/v1/integration/webhooks/configuration/webhooks",
            json.dumps({"name": WEBHOOK_NAME, "url": WEBHOOK_URL}).encode())
        print("✓ Created webhook")
        return True
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code in (400, 409) and "exists" in body.lower():
            api("PUT", f"/api/v1/integration/webhooks/configuration/webhooks/{WEBHOOK_NAME}",
                json.dumps({"url": WEBHOOK_URL}).encode())
            print("✓ Webhook exists, updated URL")
            return True
        print(f"✗ Webhook failed: {e.code} {body[:200]}")
        return False


# --- 2. Log monitor (create) ---

def create_log_monitor(service: str):
    """Create Log monitor with {{log.attributes.X}} in message and @webhook-NAME."""
    payload = {
        "name": "[Webhook Sandbox] Log monitor - DELETE ME",
        "type": "log alert",
        "query": f'logs("service:{service}").rollup("count").last("5m") > 0',
        "message": (
            "Application: {{log.attributes.applicationNumber}} | TxnID: {{log.attributes.paymentTxnId}} | "
            "Status: {{log.attributes.status}} | Amount: {{log.attributes.amount}} | "
            "Error: {{log.attributes.errMsg}} | Log: {{log.link}}\n\n@webhook-{WEBHOOK_NAME}"
        ),
        "options": {
            "thresholds": {"critical": 0},
            "enable_logs_sample": True,
            "notify_no_data": False,
        },
    }
    r = api("POST", "/api/v1/monitor", json.dumps(payload).encode())
    return r.get("id")


def delete_monitor(mid: int):
    try:
        api("DELETE", f"/api/v1/monitor/{mid}")
        return True
    except Exception:
        return False


# --- 3. Send log ---

def send_log(service: str):
    from log_payload import get_log_payload
    payload = get_log_payload(service, message_format="singleline")
    url = f"{INTAKE_HOST}/v1/input"
    data = json.dumps([payload]).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={"DD-API-KEY": DD_API_KEY, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        pass
    print("✓ Log sent")


# --- 4. Poll webhook.site ---

def poll_webhook(uuid: str, timeout: int = 120, interval: int = 15):
    """Poll webhook.site for POST with resolved attributes (APP-12345, TXN-67890)."""
    url = f"https://webhook.site/token/{uuid}/requests?sorting=newest&per_page=10"
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=15) as r:
                resp = json.loads(r.read().decode())
        except Exception as e:
            print(f"  Poll: {e}")
            time.sleep(interval)
            continue
        for item in resp.get("data", []):
            if item.get("method") != "POST":
                continue
            content = item.get("content") or ""
            if "APP-12345" not in content and "TXN-67890" not in content:
                continue
            try:
                payload = json.loads(content)
                text = (payload.get("text_only_msg") or payload.get("body") or
                        payload.get("description") or payload.get("message") or "")
                # CRM payload: description is inside input_data JSON string
                if not text and "input_data" in payload:
                    inner = json.loads(payload["input_data"])
                    text = inner.get("request", {}).get("description", "")
                if "APP-12345" in str(text) or "TXN-67890" in str(text):
                    return payload
            except Exception:
                pass
        time.sleep(interval)
    return None


def main():
    if not DD_API_KEY or not DD_APP_KEY:
        print("Error: Set DD_API_KEY and DD_APP_KEY")
        sys.exit(1)
    if not WEBHOOK_URL or "webhook.site" not in WEBHOOK_URL:
        print("Error: Set WEBHOOK_URL (e.g. https://webhook.site/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)")
        sys.exit(1)
    uuid_match = re.search(r"webhook\.site/([a-f0-9-]{36})", WEBHOOK_URL)
    if not uuid_match:
        print("Error: Could not parse UUID from WEBHOOK_URL")
        sys.exit(1)
    uuid = uuid_match.group(1)
    service = f"webhook-sandbox-{int(time.time())}"

    print("Step 1: Creating/updating webhook integration...")
    if not create_webhook():
        sys.exit(1)

    print("\nStep 2: Creating Log monitor...")
    mon_id = create_log_monitor(service)
    if not mon_id:
        print("✗ Monitor creation failed")
        sys.exit(1)
    print(f"  Monitor ID {mon_id}")

    print("\nStep 3: Sending log...")
    send_log(service)

    print("\nStep 4: Waiting 90s for log indexing + monitor evaluation...")
    time.sleep(90)

    print("\nStep 5: Polling webhook.site...")
    payload = poll_webhook(uuid, timeout=60)

    print("\nStep 6: Cleanup...")
    delete_monitor(mon_id)

    if payload:
        text = (payload.get("text_only_msg") or payload.get("body") or
                payload.get("description") or payload.get("message") or "")
        print("\n" + "=" * 60)
        print("✓ Webhook received")
        print("=" * 60)
        print((str(text)[:500] + "..." if len(str(text)) > 500 else str(text)))
        if "APP-12345" in str(text):
            print("\n✓ Log attributes resolved in $TEXT_ONLY_MSG")
        print("=" * 60)
    else:
        print("\n✗ No webhook received. Check https://webhook.site/#!/view/" + uuid)
        sys.exit(1)


if __name__ == "__main__":
    main()
