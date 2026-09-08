#!/usr/bin/env python3
"""Stub Google Search Console endpoint for tests/fm-gsc-pull.test.sh.

Serves the two endpoints bin/fm-gsc-pull.sh actually calls - the OAuth token
exchange and searchAnalytics.query - with responses shaped like Google's, so
the test exercises the real curl/jq/paging path instead of a fake of it.

The scenario is chosen by the FM_GSC_STUB_MODE environment variable:
  ok        two Hebrew queries and two pages per day, plus per-day totals
  paged     260 query rows for one day, to drive startRow paging
  exactmax  exactly 100 query rows, so a pull at --max-rows 100 sits on the
            boundary: the cap is reached but nothing was left behind
  disabled  403 SERVICE_DISABLED
  denied    403 on the property (not a user / revoked)
  quota     429 rate limit
  nosites   an authorized credential with no properties shared with it
  nohorizon like "ok", but no metadata at all, the way Google answers when it
            reports no first_incomplete_date
  horizon   like "ok", but a day on or after FM_GSC_STUB_HORIZON is still
            unsettled and comes back with no rows, the way Google answers a
            finalized-only request for a day it has not finished settling
  badtoken  400 invalid_grant from the token endpoint
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("FM_GSC_STUB_MODE", "ok")
# The first date Google still considers incomplete, reported as metadata on
# every response the way the API reports it.
HORIZON = os.environ.get("FM_GSC_STUB_HORIZON", "2026-09-06")

# Deliberately Hebrew, including a final-form letter, so the test proves the
# bytes survive the whole pipeline rather than just that some row appeared.
HEB_Q1 = "יום גיבוש לחברות"
HEB_Q2 = "אטרקציות בטבע"
HEB_PAGE = "https://batevashelanu.co.il/פעילות-גיבוש-לחברות/"


def err(code, status, reason, message):
    return code, {
        "error": {
            "code": code,
            "message": message,
            "status": status,
            "errors": [{"message": message, "reason": reason}],
            "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo",
                         "reason": reason}],
        }
    }


def analytics(body):
    dims = body.get("dimensions", [])
    start = body.get("startDate")
    start_row = body.get("startRow", 0)
    row_limit = body.get("rowLimit", 1000)

    if MODE == "disabled":
        return err(403, "PERMISSION_DENIED", "SERVICE_DISABLED",
                   "Google Search Console API has not been used in project 1 before or it is disabled.")
    if MODE == "denied":
        return err(403, "PERMISSION_DENIED", "forbidden",
                   "User does not have sufficient permission for site.")
    if MODE == "quota":
        return err(429, "RESOURCE_EXHAUSTED", "rateLimitExceeded",
                   "Quota exceeded for quota metric 'Queries'.")

    if MODE in ("paged", "exactmax") and dims == ["query"]:
        total = 260 if MODE == "paged" else 100
        rows = []
        for i in range(start_row, min(total, start_row + row_limit)):
            rows.append({"keys": [f"{HEB_Q1} {i}"], "clicks": 1.0,
                         "impressions": 10.0, "ctr": 0.1, "position": 5.0})
        return 200, {"rows": rows, "responseAggregationType": "byProperty"}

    if start_row > 0:
        return 200, {"rows": []}

    # An unsettled day answers a finalized-only request with nothing at all.
    if MODE == "horizon" and body.get("dataState") == "final" and start >= HORIZON:
        return 200, {"rows": [], "metadata": {"first_incomplete_date": HORIZON}}

    if dims == ["query"]:
        # Two days are pulled in the "ok" scenario; the same rows on each day
        # let the test assert the summing and impression-weighted position.
        rows = [
            {"keys": [HEB_Q1], "clicks": 5.0, "impressions": 100.0,
             "ctr": 0.05, "position": 10.0},
            {"keys": [HEB_Q2], "clicks": 1.0, "impressions": 300.0,
             "ctr": 0.00333, "position": 20.0},
        ]
    elif dims == ["page"]:
        rows = [{"keys": [HEB_PAGE], "clicks": 6.0, "impressions": 400.0,
                 "ctr": 0.015, "position": 17.5}]
    elif dims == ["date"]:
        rows = [{"keys": [start], "clicks": 6.0, "impressions": 400.0,
                 "ctr": 0.015, "position": 17.5}]
    else:
        rows = []

    out = {"rows": rows, "responseAggregationType": "byProperty"}
    # Report the freshness boundary the way the API does, so the test can
    # assert it reaches the manifest instead of being swallowed.
    if MODE != "nohorizon":
        out["metadata"] = {"first_incomplete_date": HORIZON}
    return 200, out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # keep the test output clean
        pass

    def _send(self, code, payload):
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=UTF-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        if self.path == "/token":
            if MODE == "badtoken":
                self._send(400, {"error": "invalid_grant",
                                 "error_description": "Token has been expired or revoked."})
            else:
                self._send(200, {"access_token": "stub-access-token",
                                 "expires_in": 3599, "token_type": "Bearer"})
            return
        if "/searchAnalytics/query" in self.path:
            if self.headers.get("Authorization") != "Bearer stub-access-token":
                self._send(401, {"error": {"code": 401, "message": "Invalid Credentials",
                                           "errors": [{"reason": "authError"}]}})
                return
            code, payload = analytics(json.loads(raw or b"{}"))
            self._send(code, payload)
            return
        self._send(404, {"error": {"code": 404, "message": "no such stub route"}})

    def do_GET(self):
        if self.path.endswith("/sites"):
            if MODE == "disabled":
                code, payload = err(403, "PERMISSION_DENIED", "SERVICE_DISABLED",
                                    "Google Search Console API has not been used in project 1 before or it is disabled.")
                self._send(code, payload)
                return
            if MODE == "nosites":
                # What Google actually returns for an authorized credential
                # that no property has been shared with: 200 and an empty body.
                self._send(200, {})
                return
            self._send(200, {"siteEntry": [
                {"siteUrl": "sc-domain:example.co.il", "permissionLevel": "siteOwner"},
            ]})
            return
        self._send(404, {"error": {"code": 404, "message": "no such stub route"}})


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    # The test reads the chosen port from stdout before running the script.
    sys.stdout.write(f"{server.server_port}\n")
    sys.stdout.flush()
    server.serve_forever()
