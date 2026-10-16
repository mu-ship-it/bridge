#!/usr/bin/env python3
"""Mock phone: runs the job loop against any Bridge server (stdlib only).

The mirror image of the repo's `tools/mock_box.py` — that one fakes the box for the real
app, this one fakes the app for the real box. Useful for a round trip without an iPhone:

    python3 server/tools/mock_phone.py --url https://example.org --token "$TOKEN" \
        --device my-iphone --register --once

It answers device.info, location.now and health.query with plausible synthetic data, and
reports `unknown_capability` for anything else, exactly as the app would.
"""
import argparse
import json
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

VERSION = "0.1.0 (mock)"


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


EXTRA_HEADERS = []


def call(url, token, path, device, method="GET", body=None, query=None):
    target = url.rstrip("/") + path
    if query:
        target += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(target, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/json")
    request.add_header("User-Agent", f"Bridge/{VERSION}")
    request.add_header("X-Bridge-Device", device)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    for name, value in EXTRA_HEADERS:
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        return exc.code, {"error": exc.read()[:200].decode("utf-8", "replace")}


# ------------------------------------------------------------- fake capabilities

def device_info():
    return {
        "battery_level": round(random.uniform(0.2, 1.0), 2), "battery_state": "unplugged",
        "low_power_mode": False, "model": "iPhone", "model_identifier": "iPhone17,1",
        "system_name": "iOS", "system_version": "27.0", "app_version": VERSION,
        "last_sync": now_iso(), "last_poll": now_iso(), "background_refresh": "Available",
    }


def location_now(params):
    return {
        "lat": 37.3349, "lon": -122.009, "horizontal_accuracy_m": 35, "altitude_m": 12.0,
        "speed_mps": 0, "course_deg": 90, "timestamp": now_iso(),
        "_timeout_requested": params.get("timeout", 20),
    }


def health_query(params):
    metric = params.get("metric") or "heart_rate"
    start = datetime.now(timezone.utc) - timedelta(hours=2)
    data = [
        {"date": (start + timedelta(minutes=30 * i)).strftime("%Y-%m-%d %H:%M:%S +0000"),
         "qty": 60 + i, "source": "Apple Watch"}
        for i in range(3)
    ]
    return {
        "from": start.isoformat(timespec="seconds"), "to": now_iso(),
        "interval": params.get("interval", "raw"), "count": len(data),
        "metric": {"name": metric, "units": "count/min", "data": data},
    }


def run_job(job):
    started = now_iso()
    capability, params = job.get("capability"), job.get("params") or {}
    try:
        if capability == "device.info":
            payload = device_info()
        elif capability == "location.now":
            payload = location_now(params)
        elif capability == "health.query":
            payload = health_query(params)
        else:
            return {"job_id": job["id"], "ok": False, "started_at": started,
                    "finished_at": now_iso(),
                    "error": {"code": "unknown_capability",
                              "message": f"mock phone cannot do {capability}"}}
    except Exception as exc:
        return {"job_id": job["id"], "ok": False, "started_at": started, "finished_at": now_iso(),
                "error": {"code": "failed", "message": str(exc)[:200]}}
    return {"job_id": job["id"], "ok": True, "result": payload,
            "started_at": started, "finished_at": now_iso()}


# ------------------------------------------------------------- the loop

def poll_once(args):
    status, body = call(args.url, args.token, "/bridge/jobs", args.device,
                        query={"device": args.device})
    if status != 200:
        print(f"jobs -> HTTP {status} {body}", file=sys.stderr)
        return status, 0
    jobs = body.get("jobs", [])
    print(f"jobs -> {len(jobs)} job(s); poll_after_seconds={body.get('poll_after_seconds')}")
    if not jobs:
        return status, 0
    results = [run_job(job) for job in jobs]
    for job, result in zip(jobs, results):
        print(f"  ran {job['id']} {job['capability']} ok={result['ok']}")
    status, body = call(args.url, args.token, "/bridge/results", args.device,
                        method="POST", body={"device": args.device, "results": results})
    print(f"results -> HTTP {status} {json.dumps(body)}")
    return status, len(results)


def main():
    parser = argparse.ArgumentParser(description="Mock iPhone for a Bridge server")
    parser.add_argument("--url", required=True, help="server base URL, e.g. https://example.org")
    parser.add_argument("--token", required=True, help="account token (Bearer)")
    parser.add_argument("--device", default="mock-iphone")
    parser.add_argument("--register", action="store_true", help="POST /bridge/devices first")
    parser.add_argument("--once", action="store_true", help="poll a single time and exit")
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--ping", action="store_true", help="call /bridge/ping first")
    parser.add_argument("--header", action="append", default=[], metavar="'K: V'",
                        help="extra request header; repeatable. For a server behind a proxy "
                             "that wants its own auth (SSO cookie, basic auth).")
    args = parser.parse_args()
    for raw in args.header:
        name, _, value = raw.partition(":")
        EXTRA_HEADERS.append((name.strip(), value.strip()))

    if args.ping:
        status, body = call(args.url, args.token, "/bridge/ping", args.device,
                            query={"device": args.device})
        print(f"ping -> HTTP {status} {json.dumps(body)}")
        if status != 200:
            raise SystemExit(1)
    if args.register:
        status, body = call(
            args.url, args.token, "/bridge/devices", args.device, method="POST",
            body={"device": args.device, "apns_token": "0" * 64,
                  "apns_environment": "development", "app_version": VERSION,
                  "capabilities": ["device.info", "health.query", "location.now"]})
        print(f"devices -> HTTP {status} {json.dumps(body)}")
        if status // 100 != 2:
            raise SystemExit(1)

    while True:
        status, _ = poll_once(args)
        if args.once:
            raise SystemExit(0 if status == 200 else 1)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
