"""The desk display (值班台, v0.6): what `GET /bridge/board/desk` composes for a phone parked on
a desk — the time, the weather, what wants Mu's attention, and whether he is at the desk.

Kept out of app.py so every piece is a plain function a test can call with fixed inputs.

* Weather comes from Open-Meteo (no key), for the box's configured spot, cached 15 minutes in
  this process. A failed fetch serves the last good answer marked stale, or none at all —
  the desk never waits on it for more than a few seconds.
* Attention is composed, not stored: `agent.say` / `alert` / `notify` events of the last
  24 hours, plus board rows in a state that needs a human (`over`, `stalled`), minus whatever
  the phone acknowledged with an `attention.ack` event (payload `{"ids": [...]}`).
* Room is the latest temperature / humidity report (`POST /bridge/room`, from Home Assistant);
  older than 15 minutes it is marked stale.
* Presence is fused (`fuse_presence`) from three kinds of source, first trusted one wins:
  the desk phone's front camera (`POST /bridge/presence/camera`) while fresh and not
  `dark` / `unknown`; else the study's presence sensor (a `POST /bridge/presence` source named
  in BRIDGE_ROOM_PRESENCE_SOURCES, from Home Assistant) while fresh; else the PCs' idle reports
  (every other `/bridge/presence` source). Anything older than its stale limit is ignored, never
  trusted: a sensor that dropped offline keeps its last state, so a stuck "someone" or "nobody"
  must not decide.
* `study` (v0.8, room follow by identity) says what the study as a room should do, separately from
  `present` (which still drives the desk itself): `empty` (nobody), `someone` (the room sensor,
  the camera or the PC sees a person, but it is not known to be Mu sitting down: light for the
  camera at most, nothing else), or `present` (the camera says who=mu and seated, or the camera
  is unsure (`unknown`) while 白加黑 was typed on in the last STUDY_PC_ACTIVE_SECONDS: Mu). A
  camera `other` is never Mu, even at his PC. `needs_light`: someone is there and the camera is
  too dark to see (state `dark` or light under CAMERA_FLOOR_EV) - Home Assistant then turns on
  just the light the camera needs.
* `away_s` / `away_since` say how long the fused answer has read "away" (kept per account in
  `presence_state`, flipped whenever a composed desk sees it change); once it reaches
  `away_after_s` the phone goes fully black until Mu is back.
"""
import hashlib
import json
import logging
import unicodedata
from pathlib import Path
import threading
import time
from datetime import datetime, timedelta, timezone

import config

OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"
WEATHER_TTL_SECONDS = 15 * 60
WEATHER_TIMEOUT_SECONDS = 5

ATTENTION_TYPES = ("agent.say", "alert", "notify")
ACK_TYPE = "attention.ack"
ATTENTION_LOOKBACK = timedelta(hours=24)
ACK_LOOKBACK = timedelta(hours=48)
ATTENTION_MAX = 20
ATTENTION_TEXT_MAX = 200
# House rule: an Attention title is <= 4 CJK characters or one short Latin word. Width 8, CJK counts 2.
ATTENTION_TITLE_WIDTH = 8

log = logging.getLogger("bridge.desk")
BOARD_ATTENTION_STATES = ("over", "stalled")

PRESENCE_STALE_SECONDS = 90           # a PC's idle report
CAMERA_STALE_SECONDS = 60             # the phone re-reports every 30 s while it has an opinion
ROOM_SENSOR_STALE_SECONDS = 3 * 60    # Home Assistant must re-post the sensor's state within this
AWAY_AFTER_SECONDS = 10 * 60          # fused away this long: the desk goes black (HA's room_follow uses the same 10 min)
CAMERA_STATES = ("present", "looking", "absent", "dark", "unknown")
CAMERA_DECISIVE = ("present", "looking", "absent")
CAMERA_SEES = ("present", "looking")
CAMERA_WHO = ("mu", "other", "unknown")
CAMERA_FLOOR_EV = 1.0                 # the phone's CamPresence.darkEV: under it Vision is not trusted
STUDY_PC_SOURCE = "pc"                # 白加黑
STUDY_PC_ACTIVE_SECONDS = 30          # typed on this recently: the person at 白加黑 is Mu
STUDY_STATES = ("empty", "someone", "present")
ROOM_STALE_SECONDS = 15 * 60
PROGRESS_STALE_SECONDS = 30 * 60      # a running job that stopped reporting
PROGRESS_DONE_SECONDS = 10 * 60       # a finished job's row lingers this long


def iso(moment):
    return moment.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _age(received, now):
    then = datetime.fromisoformat(received.replace("Z", "+00:00"))
    return max(0, int((now - then).total_seconds()))


# ------------------------------------------------------------------ weather

def location():
    """(lat, lon, place) from config; default Shenyang."""
    lat = float(config.get("BRIDGE_WEATHER_LAT"))
    lon = float(config.get("BRIDGE_WEATHER_LON"))
    return lat, lon, str(config.get("BRIDGE_WEATHER_PLACE") or "")


def fetch_open_meteo(lat, lon):
    """One Open-Meteo forecast call -> its JSON. Raises on any failure."""
    import httpx  # lazy, like apns.py: no import cost when nobody asks for the desk
    params = {
        "latitude": f"{lat:.4f}", "longitude": f"{lon:.4f}",
        "current": "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,is_day",
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max",
        "timezone": "auto", "forecast_days": 1,
    }
    with httpx.Client(timeout=WEATHER_TIMEOUT_SECONDS) as client:
        response = client.get(OPEN_METEO_URL, params=params)
        response.raise_for_status()
        return response.json()


def _num(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _first(values):
    return _num(values[0]) if isinstance(values, list) and values else None


def parse_open_meteo(raw):
    """Open-Meteo's answer -> the desk's weather fields. Raises ValueError when there is no
    current temperature (the one field the tile cannot do without)."""
    current = (raw or {}).get("current") or {}
    daily = (raw or {}).get("daily") or {}
    temp = _num(current.get("temperature_2m"))
    if temp is None:
        raise ValueError("no current temperature")
    code = current.get("weather_code")
    return {
        "temp_c": temp,
        "feels_c": _num(current.get("apparent_temperature")),
        "humidity": _num(current.get("relative_humidity_2m")),
        "wind_kmh": _num(current.get("wind_speed_10m")),
        "code": int(code) if isinstance(code, (int, float)) and not isinstance(code, bool) else None,
        "is_day": bool(current.get("is_day", 1)),
        "high_c": _first(daily.get("temperature_2m_max")),
        "low_c": _first(daily.get("temperature_2m_min")),
        "precip_pct": _first(daily.get("precipitation_probability_max")),
    }


class WeatherCache:
    """Latest good answer per spot, kept WEATHER_TTL_SECONDS. Thread-safe; `fetch` is injectable."""

    def __init__(self, fetch=None, clock=time.time):
        self._fetch = fetch
        self._clock = clock
        self._lock = threading.Lock()
        self._entries = {}   # (lat, lon) -> (fetched_at_epoch, fields)

    def get(self, lat, lon, place=""):
        """The desk's `weather` object, or None when there has never been a good answer."""
        key = (round(lat, 4), round(lon, 4))
        now = self._clock()
        with self._lock:
            entry = self._entries.get(key)
        stale = entry is None or now - entry[0] >= WEATHER_TTL_SECONDS
        if stale:
            try:
                fields = parse_open_meteo((self._fetch or fetch_open_meteo)(lat, lon))
                entry = (now, fields)
                with self._lock:
                    self._entries[key] = entry
                stale = False
            except Exception:  # network, HTTP, shape: the desk shows the last good answer or "—"
                if entry is None:
                    return None
        fetched_at, fields = entry
        return {**fields, "place": place or None, "lat": key[0], "lon": key[1],
                "fetched_at": iso(datetime.fromtimestamp(fetched_at, timezone.utc)),
                "age_s": max(0, int(now - fetched_at)), "stale": stale}

    def clear(self):
        with self._lock:
            self._entries.clear()


weather_cache = WeatherCache()


# ------------------------------------------------------------------ attention

def _clip(text):
    text = " ".join(str(text).split())
    return text if len(text) <= ATTENTION_TEXT_MAX else text[:ATTENTION_TEXT_MAX - 1] + "…"


def _width(char):
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


def clip_title(title, source=None):
    """An Attention title cut to ATTENTION_TITLE_WIDTH (CJK counts 2), no ellipsis; a cut is logged with its source."""
    title = " ".join(str(title).split())
    used, out = 0, []
    for char in title:
        if used + _width(char) > ATTENTION_TITLE_WIDTH:
            log.warning("attention title %r from %s clipped to %r (max %d wide, CJK = 2)",
                        title, source or "?", "".join(out), ATTENTION_TITLE_WIDTH)
            break
        out.append(char)
        used += _width(char)
    return "".join(out)


def acked_ids(ack_events):
    """Every id named in `attention.ack` events' payload `ids`."""
    ids = set()
    for event in ack_events:
        for item in ((event.get("payload") or {}).get("ids") or []):
            if isinstance(item, str):
                ids.add(item)
    return ids


def event_item(event):
    """An agent.say / alert / notify event -> an attention item."""
    payload = event.get("payload") or {}
    text = payload.get("text") if isinstance(payload.get("text"), str) and payload["text"].strip() else event["note"]
    title = payload.get("title") if isinstance(payload.get("title"), str) and payload["title"].strip() else None
    level = payload.get("level") if payload.get("level") in ("info", "warn", "critical") else (
        "warn" if event["type"] == "alert" else "info")
    return {
        "id": event["id"], "kind": event["type"], "title": clip_title(title, "event") if title else None,
        "text": _clip(text), "level": level, "ts": event["received"],
        "speak": payload.get("speak") is True, "source": "event",
    }


def board_row_id(board_name, label):
    """Stable while the row keeps its label, so an ack holds until the row clears."""
    digest = hashlib.sha256(f"{board_name}\n{label}".encode()).hexdigest()[:12]
    return f"b_{board_name}_{digest}"


def board_items(boards):
    """[(name, board, received)] -> attention items for rows in an `over` / `stalled` state."""
    items = []
    for name, board, received in boards:
        for section in (board or {}).get("sections") or []:
            for row in section.get("rows") or []:
                if row.get("state") not in BOARD_ATTENTION_STATES:
                    continue
                label = row.get("label") or ""
                detail = " · ".join(part for part in (row.get("detail"), row.get("value")) if part)
                items.append({
                    "id": board_row_id(name, label), "kind": f"board.{row['state']}",
                    "title": clip_title(label or board.get("title") or name, f"board:{name}"),
                    "text": _clip(detail or row["state"]),
                    "level": "warn" if row["state"] == "over" else "info",
                    "ts": received, "speak": False, "source": f"board:{name}",
                })
    return items


def progress_items(reports, now):
    """Latest-per-source progress reports -> attention rows. A running row goes stale after
    PROGRESS_STALE_SECONDS, a done row expires after PROGRESS_DONE_SECONDS, a failed row stays
    until acked (id `progress:<source>`)."""
    items = []
    for report in reports:
        age = _age(report["received"], now)
        state = report["state"]
        if (state == "running" and age > PROGRESS_STALE_SECONDS) or (
                state == "done" and age > PROGRESS_DONE_SECONDS):
            continue
        done, total = report["done"], report.get("total")
        pct = None if not total else max(0, min(100, int(round(100 * done / total))))
        if state == "done":
            pct = 100
        items.append({
            "id": f"progress:{report['source']}", "kind": "progress",
            "title": report["title"], "done": done, "total": total, "pct": pct,
            "unit": report.get("unit"), "eta": report.get("eta"), "note": report.get("note"),
            "state": state, "ts": report["received"],
        })
    return items


def compose_attention(events, ack_events, boards, progress=None, now=None):
    """Unacked items, newest first, at most ATTENTION_MAX. Progress rows come after the events."""
    acked = acked_ids(ack_events)
    # Events arrive oldest first; reversed, a same-second tie still reads newest first.
    items = [event_item(event) for event in reversed(events)] + board_items(boards)
    items = [item for item in items if item["id"] not in acked]
    items.sort(key=lambda item: item["ts"], reverse=True)   # stable: ties keep board order
    rows = [item for item in progress_items(progress or [], now or datetime.now(timezone.utc))
            if item["id"] not in acked]
    rows = rows[:ATTENTION_MAX]
    return items[:ATTENTION_MAX - len(rows)] + rows


# ------------------------------------------------------------------ presence

def summarize_presence(reports, now):
    """Latest-per-source reports -> {present, source, idle_s, age_s, stale_after_s, sources}.
    Present when any source reported active within PRESENCE_STALE_SECONDS."""
    sources = []
    for report in reports:
        age = _age(report["received"], now)
        sources.append({**report, "age_s": age, "fresh": age <= PRESENCE_STALE_SECONDS})
    live = [s for s in sources if s["fresh"] and s["active"]]
    best = min(live, key=lambda s: s["age_s"]) if live else (
        min(sources, key=lambda s: s["age_s"]) if sources else None)
    return {
        "present": bool(live),
        "source": best["source"] if best else None,
        "active": best["active"] if best else None,
        "idle_s": best["idle_s"] if best else None,
        "age_s": best["age_s"] if best else None,
        "stale_after_s": PRESENCE_STALE_SECONDS,
        "sources": sources,
    }


def room_presence_sources():
    """The `/bridge/presence` sources that are room sensors (someone in the study), not PCs."""
    raw = config.get("BRIDGE_ROOM_PRESENCE_SOURCES") or ""
    return frozenset(name.strip() for name in raw.split(",") if name.strip())


def summarize_camera(report, now):
    """The phone's latest camera report -> {state, light, age_s, fresh, stale_after_s}, or None.
    Its age is the older of "since it was observed" and "since the box received it", so a phone
    clock that runs ahead cannot make a report look fresher than it is."""
    if not report:
        return None
    age = max(_age(report["received"], now), _age(report["observed"], now))
    return {"state": report["state"], "light": report["light"], "age_s": age,
            "fresh": age <= CAMERA_STALE_SECONDS, "stale_after_s": CAMERA_STALE_SECONDS,
            "who": report.get("who"), "score": report.get("score"), "seated": report.get("seated")}


def summarize_room_sensor(reports, now, sources):
    """The freshest report from a room-sensor source -> {source, occupied, age_s, fresh,
    stale_after_s}; None when no such source ever reported."""
    mine = [r for r in reports if r["source"] in sources]
    if not mine:
        return None
    latest = min(mine, key=lambda r: _age(r["received"], now))
    age = _age(latest["received"], now)
    return {"source": latest["source"], "occupied": latest["active"], "age_s": age,
            "fresh": age <= ROOM_SENSOR_STALE_SECONDS, "stale_after_s": ROOM_SENSOR_STALE_SECONDS}


def fuse_presence(reports, camera, now, room_sources=None):
    """Latest-per-source presence reports + the phone's camera report -> the desk's `presence`.

    `present` / `by` / `source` / `age_s` / `stale_after_s` come from the first trusted input:
    camera (fresh, decisive) > room sensor (fresh) > PC idle (summarize_presence) > away.
    `camera` and `room_sensor` are passed through for the phone, which keeps its camera off
    while the room sensor is fresh and reads nobody."""
    room_sources = room_presence_sources() if room_sources is None else room_sources
    pcs = summarize_presence([r for r in reports if r["source"] not in room_sources], now)
    cam = summarize_camera(camera, now)
    sensor = summarize_room_sensor(reports, now, room_sources)
    fused = {**pcs, "by": "pc" if any(p["fresh"] for p in pcs["sources"]) else None,
             "sources": summarize_presence(reports, now)["sources"], "camera": cam, "room_sensor": sensor,
             "study": study_state(cam, sensor, pc_active(reports, now))}
    if cam and cam["fresh"] and cam["state"] in CAMERA_DECISIVE:
        here = cam["state"] != "absent"
        fused.update(present=here, by="camera", source="camera", active=here, idle_s=None,
                     age_s=cam["age_s"], stale_after_s=CAMERA_STALE_SECONDS)
    elif sensor and sensor["fresh"]:
        fused.update(present=sensor["occupied"], by="room", source=sensor["source"], active=sensor["occupied"],
                     idle_s=None, age_s=sensor["age_s"], stale_after_s=ROOM_SENSOR_STALE_SECONDS)
    return fused


def pc_active(reports, now, source=STUDY_PC_SOURCE, within=STUDY_PC_ACTIVE_SECONDS):
    """白加黑's keyboard / mouse used within `within` seconds: its latest report says active, and its
    idle time plus the report's age is inside the window."""
    for report in reports:
        if report["source"] == source:
            return bool(report["active"]) and (report["idle_s"] or 0) + _age(report["received"], now) <= within
    return False


def study_state(camera, sensor, pc_is_active):
    """The summarised camera + room sensor + whether 白加黑 is being typed on -> the study's
    `{state, why, who, score, seated, pc_active, needs_light}` (see the module doc)."""
    cam_fresh = bool(camera and camera["fresh"])
    sees = cam_fresh and camera["state"] in CAMERA_SEES
    who = camera.get("who") if sees and camera.get("who") in CAMERA_WHO else "unknown"
    seated = bool(sees and camera.get("seated"))
    occupied = bool(sensor and sensor["fresh"] and sensor["occupied"])
    someone = occupied or sees or pc_is_active
    too_dark = cam_fresh and (camera["state"] == "dark"
                              or (camera["light"] is not None and camera["light"] < CAMERA_FLOOR_EV))
    if who == "mu" and seated:
        state, why = "present", "camera: mu, seated"
    elif who == "unknown" and pc_is_active and someone:
        state, why = "present", "pc typed on, camera unsure"
    elif someone:
        state = "someone"
        if who == "other":
            why = "camera: not mu"
        elif who == "mu":
            why = "camera: mu, not seated yet"
        elif too_dark:
            why = "too dark for the camera"
        elif sees:
            why = "camera: someone, not recognised"
        else:
            why = "room sensor"
    else:
        state, why = "empty", "nobody"
    return {"state": state, "why": why, "who": who, "score": camera.get("score") if sees else None,
            "seated": seated, "pc_active": bool(pc_is_active), "needs_light": bool(someone and too_dark)}


def track_away(present, held, now):
    """The fused `present` + the stored {present, since} (None at first) -> (what to store, the
    presence fields {away_since, away_s, away_after_s}). `since` moves only when `present` flips,
    so the away clock starts at the first composed desk that read away; a first-ever read starts
    it now (never "away for ages")."""
    if held is None or bool(held["present"]) != bool(present):
        held = {"present": bool(present), "since": iso(now)}
    away = not held["present"]
    return held, {"away_since": held["since"] if away else None,
                  "away_s": _age(held["since"], now) if away else None,
                  "away_after_s": AWAY_AFTER_SECONDS}


# ------------------------------------------------------------------ room

def summarize_room(reports, now):
    """Latest-per-source room reports (freshest first) -> the desk's `room` object. Null fields
    when nothing was ever posted."""
    if not reports:
        return {"temp_c": None, "humidity": None, "source": None, "age_s": None, "stale": False}
    best = reports[0]
    age = _age(best["received"], now)
    return {"temp_c": best["temp_c"], "humidity": best["humidity"], "source": best["source"],
            "age_s": age, "stale": age > ROOM_STALE_SECONDS}


# ------------------------------------------------------------------ seats

SEATS_BOARD = "muster"
SEATS_SECTION = "usage"


def compose_seats(boards):
    """[(name, board, received)] -> the Usage rows of the muster board as
    [{name, pct, bar, detail}]: Max / Team / Admin weekly use. [] when there is no such board."""
    for name, board, _received in boards:
        if name != SEATS_BOARD:
            continue
        seats = []
        for section in (board or {}).get("sections") or []:
            if str(section.get("title") or "").strip().lower() != SEATS_SECTION:
                continue
            for row in section.get("rows") or []:
                bar = row.get("bar")
                if isinstance(bar, bool) or not isinstance(bar, (int, float)):
                    continue
                seats.append({"name": str(row.get("label") or "").strip().title() or "?",
                              "pct": int(round(bar * 100)), "bar": float(bar),
                              "detail": row.get("detail") or None})
        return seats
    return []


# ------------------------------------------------------------------ activity

ACTIVITY_GOALS = {"move": 500.0, "exercise": 30.0, "stand": 12.0}   # kcal, minutes, hours
KILOJOULES_PER_KCAL = 4.184


def _metric_sum(metrics, name, day):
    """Sum of a Health Auto Export metric's `qty` over entries dated `day` (YYYY-MM-DD); None
    when the export has no such metric or no entry that day."""
    for metric in metrics:
        if metric.get("name") != name:
            continue
        total, seen = 0.0, False
        for entry in metric.get("data") or []:
            qty = entry.get("qty")
            if str(entry.get("date") or "")[:10] == day and isinstance(qty, (int, float)) and not isinstance(qty, bool):
                total, seen = total + qty, True
        if not seen:
            return None
        if metric.get("units") in ("kJ", "kj"):
            total /= KILOJOULES_PER_KCAL
        return total
    return None


def parse_activity(export):
    """A Health Auto Export JSON -> {move_pct, exercise_pct, stand_pct, steps}. Each is None when
    the export lacks that metric, so the phone can show steps as text until the rings exist.
    "Today" is the day of the newest step/ring entry."""
    metrics = ((export or {}).get("data") or {}).get("metrics") or []
    names = ("step_count", "active_energy", "apple_exercise_time", "apple_stand_hour")
    dates = [str(e.get("date") or "")[:10] for m in metrics if m.get("name") in names for e in m.get("data") or []]
    empty = {"move_pct": None, "exercise_pct": None, "stand_pct": None, "steps": None}
    if not dates:
        return empty
    day = max(dates)

    def pct(name, goal):
        value = _metric_sum(metrics, name, day)
        return None if value is None else int(round(value / goal * 100))

    steps = _metric_sum(metrics, "step_count", day)
    return {"move_pct": pct("active_energy", ACTIVITY_GOALS["move"]),
            "exercise_pct": pct("apple_exercise_time", ACTIVITY_GOALS["exercise"]),
            "stand_pct": pct("apple_stand_hour", ACTIVITY_GOALS["stand"]),
            "steps": None if steps is None else int(round(steps))}


def _live_pct(value, goal, fallback):
    """round(value/goal*100) with Mu's own goal; ACTIVITY_GOALS fallback when the goal is null/0."""
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    if not isinstance(goal, (int, float)) or isinstance(goal, bool) or goal <= 0:
        goal = fallback
    return int(round(value / goal * 100))


def apply_live_activity(parsed, live):
    """Overlay ring percentages from desk-live.json's `activity` object onto a parsed export;
    steps stay as parsed. Returns `parsed` unchanged when there is no usable `activity` object."""
    act = (live or {}).get("activity")
    if not isinstance(act, dict):
        return parsed
    return {**parsed,
            "move_pct": _live_pct(act.get("move_kcal"), act.get("move_goal"), ACTIVITY_GOALS["move"]),
            "exercise_pct": _live_pct(act.get("exercise_min"), act.get("exercise_goal"), ACTIVITY_GOALS["exercise"]),
            "stand_pct": _live_pct(act.get("stand_hours"), act.get("stand_goal"), ACTIVITY_GOALS["stand"])}


def read_activity(directory=None):
    """The newest file in the health directory, parsed; all-None when missing or unreadable.
    A desk-live.json carrying an `activity` object supplies the rings."""
    try:
        folder = Path(directory or config.get("BRIDGE_HEALTH_DIR"))
        live_file = folder / "desk-live.json"
        if live_file.is_file():
            try:
                live = json.loads(live_file.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                live = None
            if isinstance(live, dict) and isinstance(live.get("activity"), dict):
                return apply_live_activity(parse_activity(live), live)
        newest = max((f for f in folder.iterdir() if f.is_file() and f.suffix == ".json"),
                     key=lambda f: f.stat().st_mtime)
        return parse_activity(json.loads(newest.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return parse_activity(None)
