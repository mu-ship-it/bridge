"""The box side of Bridge: the HTTP contract in docs/API.md, nothing more.

Every endpoint is scoped to the account behind the bearer token, writes one audit row, and
never logs a request or result body (results carry health and location data).

Run under systemd via run.sh; see README.md.
"""
import asyncio
import logging
import time
from contextlib import closing

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

import apns
import config
import db

VERSION = "0.1.0"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("bridge")

app = FastAPI(title="Bridge box", version=VERSION, docs_url=None, redoc_url=None, openapi_url=None)


class Unauthorized(Exception):
    pass


class BadRequest(Exception):
    def __init__(self, message):
        self.message = message


@app.exception_handler(Unauthorized)
def _unauthorized(request: Request, exc: Unauthorized):
    # Deliberately distinct from the site SSO's own 401 body, so a smoke run can tell which
    # layer answered.
    return JSONResponse({"error": "unauthorized"}, status_code=401)


@app.exception_handler(BadRequest)
def _bad_request(request: Request, exc: BadRequest):
    return JSONResponse({"error": exc.message}, status_code=400)


# ------------------------------------------------------------------ plumbing

def bearer(request):
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    return token.strip() if scheme.lower() == "bearer" else ""


def device_of(request, body=None):
    """The device id, from the query string, the X-Bridge-Device header, or the body."""
    candidates = [
        request.query_params.get("device"),
        request.headers.get("x-bridge-device"),
        (body or {}).get("device"),
    ]
    for value in candidates:
        if value and str(value).strip():
            return str(value).strip()
    return None


def authenticate(conn, request, endpoint, body=None):
    """Resolve the account, audit the attempt, and keep the device's last_seen fresh."""
    device_id = device_of(request, body)
    account = db.account_for_token(conn, bearer(request))
    if account is None:
        db.audit(conn, None, device_id, endpoint, "unauthorized")
        raise Unauthorized()
    return account, device_id


def require_device(conn, account, device_id, endpoint):
    if not device_id:
        db.audit(conn, account["id"], None, endpoint, "bad_request:no_device")
        raise BadRequest("device id is required (query ?device=, X-Bridge-Device, or body)")
    return device_id


async def json_body(request):
    try:
        body = await request.json()
    except Exception:
        raise BadRequest("body must be JSON")
    if not isinstance(body, dict):
        raise BadRequest("body must be a JSON object")
    return body


# ------------------------------------------------------------------ endpoints

@app.get("/bridge/health")
def health():
    """Unauthenticated liveness for systemd and the smoke script. Reveals nothing, audits nothing."""
    return {"ok": True, "service": "bridge", "version": VERSION}


@app.get("/bridge/ping")
def ping(request: Request):
    endpoint = "GET /bridge/ping"
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint)
        with conn:
            if device_id:
                db.touch_device(conn, account["id"], device_id)
            db.audit(conn, account["id"], device_id, endpoint, "ok")
    return {"ok": True, "server_time": db.now_iso()}


@app.post("/bridge/devices")
async def register_device(request: Request):
    endpoint = "POST /bridge/devices"
    body = await json_body(request)
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint, body)
        require_device(conn, account, device_id, endpoint)
        apns_token = (body.get("apns_token") or "").strip() or None
        meta = {
            "apns_environment": body.get("apns_environment"),
            "app_version": body.get("app_version"),
            "capabilities": body.get("capabilities"),
        }
        with conn:
            db.touch_device(conn, account["id"], device_id, apns_token=apns_token, meta_updates=meta)
            db.audit(conn, account["id"], device_id, endpoint,
                     "registered" + ("" if apns_token else ":no_apns_token"))
    log.info("device registered account=%s device=%s apns_token=%s",
             account["id"], device_id, "yes" if apns_token else "no")
    return {"ok": True}


WAIT_CAP_SECONDS = 30
WAIT_TICK_SECONDS = 0.5


def wait_seconds(request):
    """`?wait=<s>` turns /bridge/jobs into a long poll. Absent = answer at once (the v0.1 shape)."""
    raw = request.query_params.get("wait")
    if raw is None or raw.strip() == "":
        return 0.0
    try:
        value = float(raw)
    except ValueError:
        raise BadRequest("wait must be a number of seconds")
    if value != value or value < 0:
        raise BadRequest("wait must be a number of seconds")
    return min(value, WAIT_CAP_SECONDS)


def _lease_once(account_id, device_id):
    # Runs on a worker thread: sqlite connections stay on the thread that opened them.
    with closing(db.connect()) as conn:
        return db.lease_jobs(conn, account_id, device_id)


@app.get("/bridge/jobs")
async def jobs(request: Request):
    endpoint = "GET /bridge/jobs"
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint)
        require_device(conn, account, device_id, endpoint)
        try:
            wait = wait_seconds(request)
        except BadRequest:
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:wait")
            raise
        with conn:
            db.touch_device(conn, account["id"], device_id)

    # Long poll: check the queue every WAIT_TICK_SECONDS until a job appears or `wait` runs out.
    # A phone that hung up (backgrounded, lost signal) must not be handed jobs it will never see,
    # so a gone client ends the wait before the next lease rather than after it.
    deadline = time.monotonic() + wait
    while True:
        rows = await asyncio.to_thread(_lease_once, account["id"], device_id)
        if rows or time.monotonic() >= deadline:
            break
        await asyncio.sleep(min(WAIT_TICK_SECONDS, max(0.0, deadline - time.monotonic())))
        if await request.is_disconnected():
            break

    with closing(db.connect()) as conn, conn:
        outcome = f"leased:{len(rows)}" + (f" wait:{wait:g}" if wait else "")
        db.audit(conn, account["id"], device_id, endpoint, outcome)
    out = []
    for row in rows:
        job = {"id": row["id"], "capability": row["capability"], "created_at": row["created"]}
        params = db.unjson(row["params_json"])
        if params:
            job["params"] = params
        out.append(job)
    return {"jobs": out, "poll_after_seconds": config.get_int("BRIDGE_POLL_AFTER_SECONDS")}


@app.post("/bridge/results")
async def results(request: Request):
    endpoint = "POST /bridge/results"
    body = await json_body(request)
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint, body)
        require_device(conn, account, device_id, endpoint)
        items = body.get("results")
        if not isinstance(items, list):
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:results")
            raise BadRequest("results must be a list")
        tally = {"accepted": 0, "duplicate": 0, "unknown": 0, "invalid": 0}
        with conn:
            db.touch_device(conn, account["id"], device_id)
            for item in items:
                if not isinstance(item, dict):
                    tally["invalid"] += 1
                    continue
                tally[db.record_result(conn, account["id"], device_id, item)] += 1
            db.audit(conn, account["id"], device_id, endpoint,
                     "accepted:{accepted} dup:{duplicate} unknown:{unknown}".format(**tally))
    # Counts only — a result body may hold heart rate or a home address.
    log.info("results account=%s device=%s %s", account["id"], device_id, tally)
    return {"ok": True, **tally}


if __name__ == "__main__":
    import uvicorn

    host, port = config.listen()
    uvicorn.run(app, host=host, port=port, log_level="info")
