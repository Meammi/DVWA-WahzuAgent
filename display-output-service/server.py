import html
import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "9000"))
MAX_MESSAGES = int(os.getenv("MAX_MESSAGES", "100"))
MESSAGES: list[dict[str, Any]] = []


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: Any) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def render_page() -> bytes:
    items = []
    for message in reversed(MESSAGES):
        alert = message.get("alert") or {}
        title = f"Rule {alert.get('rule_id') or '-'} - Level {alert.get('rule_level') or '-'}"
        items.append(
            "<article class='msg'>"
            f"<div class='meta'>{html.escape(str(message.get('received_at', '')))}</div>"
            f"<h2>{html.escape(title)}</h2>"
            f"<p><b>Agent:</b> {html.escape(str(alert.get('agent_name') or '-'))}</p>"
            f"<p><b>Description:</b> {html.escape(str(alert.get('description') or '-'))}</p>"
            f"<pre>{html.escape(str(message.get('analysis') or ''))}</pre>"
            "</article>"
        )
    content = "\n".join(items) or "<p class='empty'>No alerts received yet.</p>"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="10">
  <title>Display Output</title>
  <style>
    body {{ margin: 0; font-family: Arial, sans-serif; background: #101214; color: #eceff1; }}
    main {{ max-width: 900px; margin: 0 auto; padding: 24px; }}
    h1 {{ font-size: 24px; margin: 0 0 18px; }}
    .msg {{ background: #1b2024; border: 1px solid #303840; border-radius: 8px; padding: 16px; margin: 0 0 14px; }}
    .meta {{ color: #9aa4ad; font-size: 13px; margin-bottom: 8px; }}
    h2 {{ font-size: 18px; margin: 0 0 10px; }}
    pre {{ white-space: pre-wrap; font-family: inherit; line-height: 1.45; background: #111619; padding: 12px; border-radius: 6px; }}
    .empty {{ color: #9aa4ad; }}
  </style>
</head>
<body>
  <main>
    <h1>Display Output</h1>
    {content}
  </main>
</body>
</html>
""".encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/":
            body = render_page()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/messages":
            json_response(self, 200, MESSAGES)
            return
        json_response(self, 404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/messages":
            json_response(self, 404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        try:
            message = json.loads(self.rfile.read(length).decode("utf-8"))
        except json.JSONDecodeError:
            json_response(self, 400, {"error": "invalid json"})
            return

        if not isinstance(message, dict):
            json_response(self, 400, {"error": "expected json object"})
            return

        message.setdefault("received_at", datetime.now(timezone.utc).isoformat())
        MESSAGES.append(message)
        del MESSAGES[:-MAX_MESSAGES]
        json_response(self, 201, {"status": "ok", "count": len(MESSAGES)})

    def log_message(self, format: str, *args: Any) -> None:
        print(f"{self.address_string()} - {format % args}")


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Display output service listening on {HOST}:{PORT}")
    server.serve_forever()
