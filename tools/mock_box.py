#!/usr/bin/env python3
"""Local mock of the box for simulator testing (stdlib only).

    python3 tools/mock_box.py [--port 8787] [--token devtoken]

In the app, set Box URL to http://localhost:8787 and Token to the --token value.
Enqueue a job:
    curl -s -XPOST localhost:8787/_enqueue -d '{"capability":"device.info"}'
Results and ingest bodies are printed to stdout (ingest is summarised, not dumped).
"""
import argparse
import json
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

QUEUE = []          # jobs not yet leased
LEASED = {}         # job_id -> (job, lease_expiry)
LEASE_SECONDS = 120


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Handler(BaseHTTPRequestHandler):
    token = "devtoken"

    def _send(self, code, body=None):
        data = json.dumps(body if body is not None else {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def _authed(self, bearer):
        expected = f"Bearer {self.token}" if bearer else self.token
        if self.headers.get("Authorization") != expected:
            self._send(401, {"error": "bad token"})
            return False
        return True

    def _lease(self):
        t = time.time()
        for jid, (job, exp) in list(LEASED.items()):
            if exp < t:
                del LEASED[jid]
                QUEUE.append(job)
        jobs = QUEUE[:]
        QUEUE.clear()
        for j in jobs:
            LEASED[j["id"]] = (j, t + LEASE_SECONDS)
        return jobs

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/bridge/ping":
            if self._authed(True):
                self._send(200, {"ok": True, "server_time": now_iso()})
        elif path == "/bridge/jobs":
            if not self._authed(True):
                return
            try:  # ?wait=<s>: long poll, as in docs/API.md (capped at 30 s)
                wait = min(30.0, max(0.0, float(parse_qs(url.query).get("wait", ["0"])[0])))
            except ValueError:
                return self._send(400, {"error": "wait must be a number of seconds"})
            deadline = time.time() + wait
            while True:
                jobs = self._lease()
                if jobs or time.time() >= deadline:
                    break
                time.sleep(0.5)
            self._send(200, {"jobs": jobs, "poll_after_seconds": 30})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/_enqueue":
            job = self._body()
            job.setdefault("id", "j_" + uuid.uuid4().hex[:8])
            job.setdefault("created_at", now_iso())
            QUEUE.append(job)
            print("enqueued", json.dumps(job))
            self._send(200, job)
        elif path == "/bridge/results":
            if not self._authed(True):
                return
            body = self._body()
            for r in body.get("results", []):
                LEASED.pop(r.get("job_id"), None)
                print("RESULT", json.dumps(r, indent=2))
            self._send(200, {"ok": True})
        elif path == "/bridge/devices":
            if not self._authed(True):
                return
            body = self._body()
            print("DEVICE", body.get("device"), "caps", body.get("capabilities"), "apns token len", len(body.get("apns_token", "")))
            self._send(200, {"ok": True})
        elif path == "/hk/ingest":
            if not self._authed(False):
                return
            data = self._body().get("data", {})
            counts = {m["name"]: len(m.get("data", [])) for m in data.get("metrics", [])}
            print("INGEST", counts, "workouts", len(data.get("workouts", [])))
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):  # keep stdout for payloads; never echo headers (token)
        print(f"{self.command} {urlparse(self.path).path} -> {args[1] if len(args) > 1 else ''}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--token", default="devtoken")
    a = ap.parse_args()
    Handler.token = a.token
    print(f"mock box on http://localhost:{a.port}")
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()
