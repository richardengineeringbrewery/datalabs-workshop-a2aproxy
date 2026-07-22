"""Thin A2A auth-translation proxy.

Gemini Enterprise authenticates directly against Google's OAuth2 endpoints
(using a Web application client registered via setup-oauth.sh) and presents
the resulting Bearer token to this proxy. The proxy does not validate that
token — it forwards every A2A call upstream to Elastic using an API key
instead. Config via env vars:

  ELASTIC_A2A_URL       (required) Elastic's A2A JSON-RPC endpoint.
  ELASTIC_API_KEY       (required) Sent upstream as "Authorization: ApiKey ...".
  ELASTIC_AGENT_CARD_URL (optional) Elastic's real agent card, used as a
                          template; its security scheme is replaced with ours.
  PORT                  (optional) default 8080.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GOOGLE_AUTHORIZATION_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"

PORT = int(os.environ.get("PORT", "8080"))
ELASTIC_A2A_URL = os.environ.get("ELASTIC_A2A_URL")
ELASTIC_API_KEY = os.environ.get("ELASTIC_API_KEY")
ELASTIC_AGENT_CARD_URL = os.environ.get("ELASTIC_AGENT_CARD_URL")

if not ELASTIC_A2A_URL or not ELASTIC_API_KEY:
    sys.exit("ELASTIC_A2A_URL and ELASTIC_API_KEY must be set")

AGENT_CARD_PATHS = ("/.well-known/agent-card.json", "/.well-known/agent.json")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in AGENT_CARD_PATHS:
            self._serve_agent_card()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        self._proxy_to_elastic()

    def _serve_agent_card(self):
        try:
            card = self._fetch_upstream_card()
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            self._respond_json(502, {"error": f"failed to fetch upstream agent card: {exc}"})
            return

        proto = self.headers.get("X-Forwarded-Proto", "https")
        base = f"{proto}://{self.headers.get('Host')}"
        card["url"] = base + "/"
        card["securitySchemes"] = {
            "oauth2": {
                "type": "oauth2",
                "flows": {
                    "authorizationCode": {
                        "authorizationUrl": GOOGLE_AUTHORIZATION_URL,
                        "tokenUrl": GOOGLE_TOKEN_URL,
                        "scopes": {"openid": "identity"},
                    }
                },
            }
        }
        card["security"] = [{"oauth2": ["openid"]}]
        self._respond_json(200, card)

    def _fetch_upstream_card(self):
        if not ELASTIC_AGENT_CARD_URL:
            return {"name": "proxied-agent", "description": "", "version": "1.0.0",
                    "capabilities": {}, "skills": []}
        req = urllib.request.Request(
            ELASTIC_AGENT_CARD_URL,
            headers={"Authorization": f"ApiKey {ELASTIC_API_KEY}"},
        )
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode("utf-8")
        # Elastic's agent card uses triple-quoted strings for multi-line
        # description fields, which isn't valid JSON — repair before parsing.
        fixed = re.sub(r'"""(.*?)"""', lambda m: json.dumps(m.group(1)), raw, flags=re.DOTALL)
        return json.loads(fixed)

    def _proxy_to_elastic(self):
        body = self._drain_body()
        req = urllib.request.Request(
            ELASTIC_A2A_URL,
            data=body,
            method="POST",
            headers={
                "Content-Type": self.headers.get("Content-Type", "application/json"),
                "Authorization": f"ApiKey {ELASTIC_API_KEY}",
                "kbn-xsrf": "true",
            },
        )
        try:
            with urllib.request.urlopen(req) as resp:
                self._stream_response(resp.status, resp)
        except urllib.error.HTTPError as exc:
            self._stream_response(exc.code, exc)
        except urllib.error.URLError as exc:
            self._respond_json(502, {"error": f"upstream request failed: {exc}"})

    def _stream_response(self, status, resp):
        self.send_response(status)
        self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
        self.end_headers()
        while True:
            chunk = resp.read(8192)
            if not chunk:
                break
            self.wfile.write(chunk)

    def _drain_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(length) if length else b""

    def _respond_json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
