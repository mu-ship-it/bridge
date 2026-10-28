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
* Presence is the latest report per source (`POST /bridge/presence`); a report older than
  90 s counts as away.
"""
import hashlib
import json
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
BOARD_ATTENTION_STATES = ("over", "stalled")

PRESENCE_STALE_SECONDS = 90
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
        "id": event["id"], "kind": event["type"], "title": _clip(title) if title else None,
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
                    "title": _clip(f"{board.get('title') or name} · {label}"),
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


def read_activity(directory=None):
    """The newest file in the health directory, parsed; all-None when missing or unreadable."""
    try:
        folder = Path(directory or config.get("BRIDGE_HEALTH_DIR"))
        newest = max((f for f in folder.iterdir() if f.is_file() and f.suffix == ".json"),
                     key=lambda f: f.stat().st_mtime)
        return parse_activity(json.loads(newest.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return parse_activity(None)
