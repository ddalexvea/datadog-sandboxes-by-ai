#!/usr/bin/env python3
"""Mock CRM endpoint that validates incoming JSON payloads like the real CRM would."""

import json
from http.server import HTTPServer, BaseHTTPRequestHandler

class CRMHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8')

        try:
            outer = json.loads(body)
            input_data = outer.get("input_data", "")
            inner = json.loads(input_data)
            subject = inner.get("request", {}).get("subject", "N/A")
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            resp = json.dumps({"status": "success", "case_id": "CASE-001", "subject": subject})
            self.wfile.write(resp.encode())
            print(f"  [200 OK] Created case with subject: {subject[:60]}")
        except json.JSONDecodeError as e:
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            resp = json.dumps({"error": f"Invalid JSON: {str(e)}"})
            self.wfile.write(resp.encode())
            print(f"  [400 ERROR] Malformed JSON: {str(e)[:80]}")

    def log_message(self, format, *args):
        pass  # Suppress default logging

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 8899), CRMHandler)
    print("Mock CRM server running on http://127.0.0.1:8899")
    server.serve_forever()
