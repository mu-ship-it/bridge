"""The box side of Bridge: the HTTP contract in docs/API.md, nothing more.

Every endpoint is scoped to the account behind the bearer token, writes one audit row, and
never logs a request or result body (results carry health and location data).

Run under systemd via run.sh; see README.md.
"""
import asyncio
import logging
import math
import re
import json
import time
from contextlib import closing
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse

import apns
import config
import db
import desk
import suggest

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


SHORTCUT_FILE = re.compile(r"^[a-z0-9][a-z0-9-]*\.shortcut$")


@app.get("/bridge/shortcuts/{name}")
def shortcut_file(name: str):
    """A signed shortcut for the phone to import (`shortcuts://import-shortcut?url=…`).

    Unauthenticated on purpose: the Shortcuts app fetches the URL itself and cannot send a
    bearer token. Only signed recipe files live here (no secrets, nothing per-user), and only
    plain `<slug>.shortcut` names are served — never `*.unsigned.shortcut`, never a path.
    """
    if not SHORTCUT_FILE.match(name):
        return JSONResponse({"error": "not found"}, status_code=404)
    path = Path(config.get("BRIDGE_SHORTCUTS_DIR")).expanduser() / name
    if not path.is_file():
        return JSONResponse({"error": "not found"}, status_code=404)
    return FileResponse(path, media_type="application/octet-stream", filename=name)


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


EVENT_TYPE = re.compile(r"^[a-z][a-z0-9._-]{0,63}$")
EVENTS_PER_POST = 100
EVENT_PAYLOAD_MAX_BYTES = 64 * 1024
EVENT_NOTE_MAX = 500
EVENTS_LIST_DEFAULT, EVENTS_LIST_MAX = 100, 500


def iso_utc(raw, field):
    try:
        return db.normalize_iso(raw)
    except (TypeError, ValueError):
        raise BadRequest(f"{field} must be an ISO-8601 time with a timezone (e.g. ...Z)")


def parse_event(item):
    """One event from the phone: {type, ts?, payload?, note}. Like a job, it must say in plain
    words what it is — the note is required."""
    if not isinstance(item, dict):
        raise BadRequest("each event must be a JSON object")
    event_type = item.get("type")
    if not isinstance(event_type, str) or not EVENT_TYPE.match(event_type):
        raise BadRequest("type must be lowercase letters, digits, '.', '_' or '-' (max 64)")
    note = item.get("note")
    if not isinstance(note, str) or not note.strip():
        raise BadRequest("note is required: say in plain words what this event is")
    payload = item.get("payload")
    if payload is not None and not isinstance(payload, dict):
        raise BadRequest("payload must be a JSON object")
    if payload is not None and len(json.dumps(payload)) > EVENT_PAYLOAD_MAX_BYTES:
        raise BadRequest(f"payload is larger than {EVENT_PAYLOAD_MAX_BYTES // 1024} KB")
    ts = iso_utc(item["ts"], "ts") if item.get("ts") is not None else db.now_iso()
    return event_type, ts, note.strip()[:EVENT_NOTE_MAX], payload


def record_heartbeat(conn, account_id, device_id, ts, payload):
    """A `heartbeat` event also updates the device record: duty on/off and when it last beat."""
    duty = bool((payload or {}).get("duty"))
    meta = {"duty": duty, "heartbeat_at": ts}
    if (payload or {}).get("app_version"):
        meta["app_version"] = payload["app_version"]
    db.touch_device(conn, account_id, device_id, meta_updates=meta)


@app.post("/bridge/events")
async def post_events(request: Request):
    """Device-originated events. Body: one event, or {"events": [...]} for a batch (all or none)."""
    endpoint = "POST /bridge/events"
    body = await json_body(request)
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint, body)
        require_device(conn, account, device_id, endpoint)
        items = body["events"] if "events" in body else [body]
        try:
            if not isinstance(items, list) or not items:
                raise BadRequest("events must be a non-empty list")
            if len(items) > EVENTS_PER_POST:
                raise BadRequest(f"at most {EVENTS_PER_POST} events per request")
            parsed = [parse_event(item) for item in items]
        except BadRequest:
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:event")
            raise
        ids, types = [], {}
        with conn:
            db.touch_device(conn, account["id"], device_id)
            for event_type, ts, note, payload in parsed:
                ids.append(db.add_event(conn, account["id"], device_id, event_type, ts, note, payload))
                types[event_type] = types.get(event_type, 0) + 1
                if event_type == "heartbeat":
                    record_heartbeat(conn, account["id"], device_id, ts, payload)
            # Types and counts only — a speech segment is what Mu said out loud.
            db.audit(conn, account["id"], device_id, endpoint,
                     "stored:" + ",".join(f"{t}={n}" for t, n in sorted(types.items())))
    log.info("events account=%s device=%s %s", account["id"], device_id, types)
    return {"ok": True, "stored": len(ids), "ids": ids}


@app.get("/bridge/events")
def get_events(request: Request):
    """For the agent: events of this account, oldest first, optionally by device / type / since."""
    endpoint = "GET /bridge/events"
    q = request.query_params
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint)
        try:
            event_type = q.get("type") or None
            if event_type is not None and not EVENT_TYPE.match(event_type):
                raise BadRequest("type must be lowercase letters, digits, '.', '_' or '-'")
            since = (q.get("since") or "").strip() or None
            if since and not since.startswith("e_"):
                since = iso_utc(since, "since")
            raw_limit = q.get("limit")
            limit = int(raw_limit) if raw_limit else EVENTS_LIST_DEFAULT
            if limit < 1:
                raise ValueError
        except ValueError:
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:limit")
            raise BadRequest("limit must be a positive integer")
        except BadRequest:
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:query")
            raise
        rows = db.list_events(conn, account["id"], device_id, since, event_type,
                              min(limit, EVENTS_LIST_MAX))
        with conn:
            db.audit(conn, account["id"], device_id, endpoint, f"listed:{len(rows)}")
    events = [db.event_dict(row) for row in rows]
    # `next`: pass back as ?since= to continue after the last event returned.
    return {"events": events, "next": events[-1]["id"] if events else since}


FEED_DEFAULT, FEED_MAX = 5, 50
SUMMARY_MAX = 80
FEED_STATUS = {"queued": "queued", "leased": "running", "done": "done", "failed": "failed"}


def one_line(text, limit=SUMMARY_MAX):
    """Plain text on one line, at most `limit` characters (an ellipsis marks a cut)."""
    flat = " ".join(str(text).split())
    return flat if len(flat) <= limit else flat[:limit - 1].rstrip() + "…"


def feed_summary(capability, params, envelope):
    """One short line for a widget: what the job came to. Never the whole result — a widget sits
    on the lock screen, so a summary says "heart_rate: 25 points", not the 25 heart rates."""
    params = params or {}
    if envelope is None:
        return ""
    if not envelope.get("ok"):
        error = envelope.get("error") or {}
        return one_line(error.get("message") or error.get("code") or "failed")
    result = envelope.get("result") or {}
    if capability in ("speak", "agent.say") and params.get("text"):
        return one_line(params["text"])
    if capability == "device.info" and isinstance(result.get("battery_level"), (int, float)):
        line = f"battery {round(result['battery_level'] * 100)}%"
        state = result.get("battery_state")
        if state and state != "unknown":
            line += " " + ("charging" if state == "charging" else state)
        return one_line(line)
    if capability == "health.query" and isinstance(result.get("metric"), dict):
        metric = result["metric"]
        count = result.get("count")
        if not isinstance(count, int):
            count = len(metric.get("data") or [])
        return one_line(f"{metric.get('name') or params.get('metric') or 'health'}: "
                        f"{count} point{'' if count == 1 else 's'}")
    if capability == "location.now" and "lat" in result and "lon" in result:
        line = f"{result['lat']:.4f}, {result['lon']:.4f}"
        if isinstance(result.get("horizontal_accuracy_m"), (int, float)):
            line += f" ±{round(result['horizontal_accuracy_m'])} m"
        return one_line(line)
    if isinstance(result, dict) and isinstance(result.get("count"), int):
        return one_line(f"{result['count']} item{'' if result['count'] == 1 else 's'}")
    return "done"


def feed_row(row):
    params = db.unjson(row["params_json"]) or {}
    envelope = db.unjson(row["result_json"])
    finished = None
    if row["status"] in ("done", "failed"):
        finished = (envelope or {}).get("finished_at") or row["updated"]
    note = params.get("note")
    return {
        "id": row["id"], "capability": row["capability"],
        "note": one_line(note, EVENT_NOTE_MAX) if isinstance(note, str) and note.strip() else None,
        "status": FEED_STATUS.get(row["status"], row["status"]), "finished_at": finished,
        "summary": feed_summary(row["capability"], params, envelope),
    }


@app.get("/bridge/feed")
def feed(request: Request):
    """For the phone's widgets: this device's last jobs, newest first, each with a one-line
    summary, plus the agent's latest agent.say line."""
    endpoint = "GET /bridge/feed"
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint)
        require_device(conn, account, device_id, endpoint)
        raw_limit = request.query_params.get("limit")
        try:
            limit = int(raw_limit) if raw_limit else FEED_DEFAULT
            if limit < 1:
                raise ValueError
        except ValueError:
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:limit")
            raise BadRequest("limit must be a positive integer")
        rows = db.recent_jobs(conn, account["id"], device_id, min(limit, FEED_MAX))
        said = db.last_job_of(conn, account["id"], device_id, "agent.say")
        with conn:
            db.touch_device(conn, account["id"], device_id)
            db.audit(conn, account["id"], device_id, endpoint, f"listed:{len(rows)}")
    said_text = (db.unjson(said["params_json"]) or {}).get("text") if said else None
    return {
        "jobs": [feed_row(row) for row in rows],
        "agent_line": said_text if isinstance(said_text, str) and said_text.strip() else None,
        "server_time": db.now_iso(),
    }



def job_record(row):
    if row is None:
        return None
    return {"id": row["id"], "capability": row["capability"], "status": row["status"],
            "updated": row["updated"], "params": db.unjson(row["params_json"]) or {}}


def timezone_of(request, conn, account, device_id, endpoint):
    """?tz=<IANA name> (the phone's), else the box's own local zone."""
    raw = request.query_params.get("tz")
    if not raw:
        return datetime.now().astimezone().tzinfo
    try:
        return ZoneInfo(raw)
    except (ValueError, ZoneInfoNotFoundError):
        with conn:
            db.audit(conn, account["id"], device_id, endpoint, "bad_request:tz")
        raise BadRequest("tz must be an IANA time zone name")


@app.get("/bridge/suggest")
def get_suggest(request: Request):
    """For the Suggest widget: up to 6 things to open right now, by rule (see suggest.py)."""
    endpoint = "GET /bridge/suggest"
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint)
        require_device(conn, account, device_id, endpoint)
        tz = timezone_of(request, conn, account, device_id, endpoint)
        now = suggest.utc_now()
        since = (now - suggest.TAP_LOOKBACK).isoformat(timespec="seconds").replace("+00:00", "Z")
        calendar = db.last_finished_job_of(conn, account["id"], device_id, "calendar.events")
        items = suggest.suggest(
            now, tz, suggest.load_catalog(),
            taps=[(row["item_id"], row["ts"]) for row in db.taps_since(conn, account["id"], device_id, since)],
            calendar_result=((db.unjson(calendar["result_json"]) or {}).get("result") if calendar else None),
            failed_job=job_record(db.last_finished_job(conn, account["id"], device_id)),
            lanes=suggest.load_lanes(),
            served=db.served_items(conn, account["id"], device_id),
        )
        with conn:
            db.touch_device(conn, account["id"], device_id)
            db.remember_served(conn, account["id"], device_id, items)
            db.audit(conn, account["id"], device_id, endpoint, f"listed:{len(items)}")
    return {"generated_at": db.now_iso(), "items": items}


@app.post("/bridge/suggest/tap")
async def post_suggest_tap(request: Request):
    """The phone says a Suggest slot was tapped; the time-of-day rule learns from these."""
    endpoint = "POST /bridge/suggest/tap"
    body = await json_body(request)
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint, body)
        require_device(conn, account, device_id, endpoint)
        item_id = body.get("id")
        if not isinstance(item_id, str) or not suggest.ID_RE.match(item_id):
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:id")
            raise BadRequest("id must be a suggestion id")
        with conn:
            db.touch_device(conn, account["id"], device_id)
            db.add_tap(conn, account["id"], device_id, item_id)
            db.audit(conn, account["id"], device_id, endpoint, "tapped")
    return {"ok": True}


# ------------------------------------------------------------------ boards (v0.6)

BOARD_NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
BOARD_MAX_BYTES = 64 * 1024
BOARD_SECTIONS_MAX = 16
BOARD_ROWS_MAX = 64
BOARD_TEXT_MAX = 200
BOARD_URL_MAX = 2048
BOARD_STATES = ("ok", "over", "stalled", "idle")
BOARD_COLOR = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")


def _board_text(value, where, limit=BOARD_TEXT_MAX, required=False):
    if value is None and not required:
        return None
    if not isinstance(value, str) or (required and not value.strip()):
        raise BadRequest(f"{where} must be a{' non-empty' if required else ''} string")
    if len(value) > limit:
        raise BadRequest(f"{where} is longer than {limit} characters")
    return value


def _board_fraction(value, where):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise BadRequest(f"{where} must be a number >= 0 or null")
    return value


def parse_board(body):
    """The generic board a widget renders (see docs/API.md). Returns it with only known fields."""
    sections = body.get("sections")
    if not isinstance(sections, list):
        raise BadRequest("sections must be a list")
    if len(sections) > BOARD_SECTIONS_MAX:
        raise BadRequest(f"at most {BOARD_SECTIONS_MAX} sections")
    board = {"title": _board_text(body.get("title"), "title"), "updated_at": None, "sections": []}
    if body.get("updated_at") is not None:
        try:
            board["updated_at"] = db.normalize_iso(body["updated_at"])
        except ValueError:
            raise BadRequest("updated_at must be ISO-8601 with a timezone")
    for i, section in enumerate(sections):
        if not isinstance(section, dict) or not isinstance(section.get("rows"), list):
            raise BadRequest(f"sections[{i}] must be an object with a rows list")
        if len(section["rows"]) > BOARD_ROWS_MAX:
            raise BadRequest(f"sections[{i}] has more than {BOARD_ROWS_MAX} rows")
        rows = []
        for j, row in enumerate(section["rows"]):
            where = f"sections[{i}].rows[{j}]"
            if not isinstance(row, dict):
                raise BadRequest(f"{where} must be an object")
            color = row.get("color")
            if color is not None and (not isinstance(color, str) or not BOARD_COLOR.match(color)):
                raise BadRequest(f"{where}.color must be #rgb or #rrggbb")
            state = row.get("state")
            if state is not None and state not in BOARD_STATES:
                raise BadRequest(f"{where}.state must be one of {', '.join(BOARD_STATES)}")
            rows.append({
                "label": _board_text(row.get("label"), f"{where}.label", required=True),
                "detail": _board_text(row.get("detail"), f"{where}.detail"),
                "color": color,
                "bar": _board_fraction(row.get("bar"), f"{where}.bar"),
                "bar_faded": _board_fraction(row.get("bar_faded"), f"{where}.bar_faded"),
                "value": _board_text(row.get("value"), f"{where}.value"),
                "state": state,
                "url": _board_text(row.get("url"), f"{where}.url", limit=BOARD_URL_MAX),
            })
        board["sections"].append({"title": _board_text(section.get("title"), f"sections[{i}].title"),
                                  "rows": rows})
    return board


def board_name(conn, account, device_id, endpoint, name):
    if not BOARD_NAME.match(name):
        with conn:
            db.audit(conn, account["id"], device_id, endpoint, "bad_request:name")
        raise BadRequest("board name must match [a-z0-9][a-z0-9_-]{0,31}")
    return name


DESK_BOARD = "desk"   # served composite (below), never stored: GET /bridge/board/desk is the desk display
PRESENCE_SOURCE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,31}$")
PRESENCE_IDLE_MAX = 7 * 86_400


@app.post("/bridge/presence")
async def post_presence(request: Request):
    """Something that can tell whether Mu is at the desk (a PC's last-input idle time) says so.
    Body {source, active, idle_s}; the latest report per source is kept. No device id needed."""
    endpoint = "POST /bridge/presence"
    body = await json_body(request)
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint, body)
        try:
            source, active, idle = body.get("source"), body.get("active"), body.get("idle_s", 0)
            if not isinstance(source, str) or not PRESENCE_SOURCE.match(source):
                raise BadRequest("source must match [a-z0-9][a-z0-9._-]{0,31}")
            if not isinstance(active, bool):
                raise BadRequest("active must be true or false")
            if isinstance(idle, bool) or not isinstance(idle, (int, float)) or not 0 <= idle <= PRESENCE_IDLE_MAX:
                raise BadRequest(f"idle_s must be a number of seconds, 0..{PRESENCE_IDLE_MAX}")
        except BadRequest:
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:presence")
            raise
        with conn:
            db.put_presence(conn, account["id"], source, active, int(idle))
            db.audit(conn, account["id"], device_id, endpoint, f"stored:{source}")
    return {"ok": True, "source": source}


@app.get("/bridge/board/desk")
def get_desk(request: Request):
    """For the desk display: {time, weather, attention[], presence}, composed per request
    (see desk.py). Registered before /bridge/board/{name} so it wins the route."""
    endpoint = "GET /bridge/board/desk"
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint)
        tz = timezone_of(request, conn, account, device_id, endpoint)
        now = datetime.now(tz)
        events = [db.event_dict(row) for row in db.events_of_types_since(
            conn, account["id"], desk.ATTENTION_TYPES, desk.iso(now - desk.ATTENTION_LOOKBACK))]
        ack_since = desk.iso(now - desk.ACK_LOOKBACK)
        acks = [db.event_dict(row) for row in db.events_of_types_since(
            conn, account["id"], (desk.ACK_TYPE,), ack_since, limit=1000)]
        boards = [b for b in db.list_boards(conn, account["id"]) if b[0] != DESK_BOARD]
        attention = desk.compose_attention(events, acks, boards)
        presence = desk.summarize_presence(db.list_presence(conn, account["id"]), now)
        with conn:
            if device_id:
                db.touch_device(conn, account["id"], device_id)
            db.audit(conn, account["id"], device_id, endpoint, f"read:attention={len(attention)}")
    lat, lon, place = desk.location()
    offset = now.utcoffset()
    return {
        "time": {"now": db.now_iso(), "tz": getattr(tz, "key", None) or now.tzname(),
                 "utc_offset_s": int(offset.total_seconds()) if offset is not None else 0},
        "weather": desk.weather_cache.get(lat, lon, place),
        "attention": attention,
        "presence": presence,
    }


@app.post("/bridge/board/{name}")
async def post_board(name: str, request: Request):
    """Whoever owns the board (an agent, a cron job) posts its latest state; widgets read it.
    No device id needed: the poster is usually not a phone."""
    endpoint = "POST /bridge/board"
    raw = await request.body()
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint)
        board_name(conn, account, device_id, endpoint, name)
        if name == DESK_BOARD:
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:reserved")
            raise BadRequest("board name 'desk' is reserved for the desk display")
        if len(raw) > BOARD_MAX_BYTES:
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "too_large")
            return JSONResponse({"error": f"board is larger than {BOARD_MAX_BYTES} bytes"}, status_code=413)
        try:
            try:
                body = json.loads(raw)
            except ValueError:
                raise BadRequest("body must be JSON")
            if not isinstance(body, dict):
                raise BadRequest("body must be a JSON object")
            board = parse_board(body)
        except BadRequest:
            with conn:
                db.audit(conn, account["id"], device_id, endpoint, "bad_request:board")
            raise
        rows = sum(len(section["rows"]) for section in board["sections"])
        with conn:
            db.put_board(conn, account["id"], name, board)
            db.audit(conn, account["id"], device_id, endpoint, f"stored:{name}:{rows}")
    return {"ok": True, "name": name, "rows": rows}


@app.get("/bridge/board/{name}")
def get_board(name: str, request: Request):
    """For the board widgets: the latest board under `name`, and how old it is in seconds."""
    endpoint = "GET /bridge/board"
    with closing(db.connect()) as conn:
        account, device_id = authenticate(conn, request, endpoint)
        board_name(conn, account, device_id, endpoint, name)
        found = db.get_board(conn, account["id"], name)
        with conn:
            if device_id:
                db.touch_device(conn, account["id"], device_id)
            db.audit(conn, account["id"], device_id, endpoint, f"read:{name}" if found else f"missing:{name}")
    if found is None:
        return JSONResponse({"error": "no such board"}, status_code=404)
    board, received = found
    age = time.time() - datetime.fromisoformat(received.replace("Z", "+00:00")).timestamp()
    return {"board": board, "age_s": max(0, int(age))}


if __name__ == "__main__":
    import uvicorn

    host, port = config.listen()
    uvicorn.run(app, host=host, port=port, log_level="info")
