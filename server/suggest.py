"""The Suggest widget's rules: what to put in its slots right now. Rules only, no model call.

Inputs are gathered by app.py; everything here is pure, so each rule is testable on its own.
Priority, highest first: calendar (next 2 h) → retry the last failed job → running lanes →
time-of-day taps → fixed fallback (reason ""). Duplicates keep their first (highest) slot. At most 6.

An item: {id, kind: app|capability|shortcut|url, title, glyph (1–2 chars), reason (≤14 chars),
target} — plus `params` on a capability item. `id` is URL-safe: the widget opens
bridge://suggest/<id>.
"""
import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

import config

MAX_ITEMS = 6
REASON_MAX = 14
TITLE_MAX = 40
CALENDAR_WINDOW = timedelta(hours=2)
RETRY_WINDOW = timedelta(hours=24)
TAP_LOOKBACK = timedelta(days=30)
TAP_SLOT_HOURS = 1          # a tap counts for its hour of day ± this
TAP_MIN = 2                 # taps in the slot before the rule suggests it
KINDS = ("app", "capability", "shortcut", "url")
ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

CATALOG_PATH = "~/.config/bridge/suggest.json"
EXAMPLE_PATH = Path(__file__).resolve().parent / "suggest.example.json"
LANES_PATH = "~/labbox-lanes.json"


# ------------------------------------------------------------------ helpers

def clip(text, limit):
    flat = " ".join(str(text or "").split())
    return flat if len(flat) <= limit else flat[:limit - 1].rstrip() + "…"


def glyph_of(text):
    flat = "".join(str(text or "").split())
    return flat[:1].upper() or "·"


def slug(text, limit=40):
    out = re.sub(r"[^A-Za-z0-9._-]+", "-", str(text)).strip("-")[:limit]
    return out or hashlib.sha1(str(text).encode()).hexdigest()[:10]


def parse_time(raw):
    try:
        parsed = datetime.fromisoformat(str(raw).strip().replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo else None


def item(id, kind, title, glyph, reason, target, params=None):
    out = {"id": id, "kind": kind, "title": clip(title, TITLE_MAX), "glyph": str(glyph)[:2] or "·",
           "reason": clip(reason, REASON_MAX), "target": target}
    if params is not None:
        out["params"] = params
    return out


def ago(delta):
    minutes = max(0, int(delta.total_seconds() // 60))
    if minutes < 60:
        return f"{minutes}m"
    return f"{minutes // 60}h"


# ------------------------------------------------------------------ config files

def load_catalog(path=None):
    """The app catalog [{id, title, glyph, scheme}] from ~/.config/bridge/suggest.json (or
    BRIDGE_SUGGEST_FILE), else the committed example. Bad entries are skipped."""
    candidate = Path(path or config.get("BRIDGE_SUGGEST_FILE") or CATALOG_PATH).expanduser()
    for source in (candidate, EXAMPLE_PATH):
        try:
            raw = json.loads(source.read_text())
        except (OSError, ValueError):
            continue
        entries = raw.get("apps") if isinstance(raw, dict) else raw
        if isinstance(entries, list):
            return [e for e in entries if isinstance(e, dict) and ID_RE.match(str(e.get("id", "")))
                    and e.get("title") and e.get("scheme")]
    return []


def load_lanes(path=None):
    """Lane records from the Mini's push file: a list, or {"lanes": [...]}. Missing = []."""
    source = Path(path or config.get("BRIDGE_LANES_FILE") or LANES_PATH).expanduser()
    try:
        raw = json.loads(source.read_text())
    except (OSError, ValueError):
        return []
    lanes = raw.get("lanes") if isinstance(raw, dict) else raw
    return [lane for lane in lanes if isinstance(lane, dict)] if isinstance(lanes, list) else []


def app_item(entry, reason):
    return item(f"app.{entry['id']}", "app", entry["title"], entry.get("glyph") or glyph_of(entry["title"]),
                reason, entry["scheme"])


# ------------------------------------------------------------------ rules

def calendar_rule(result, now):
    """Events starting in the next 2 h (or under way), from the last calendar.events result."""
    events = (result or {}).get("events") if isinstance(result, dict) else None
    out = []
    for event in events if isinstance(events, list) else []:
        if not isinstance(event, dict) or event.get("all_day"):
            continue
        start, end = parse_time(event.get("start")), parse_time(event.get("end"))
        if start is None:
            continue
        under_way = start <= now and end is not None and end > now
        if not (under_way or now <= start <= now + CALENDAR_WINDOW):
            continue
        title = event.get("title") or "Event"
        reason = "now" if under_way else f"in {ago(start - now)}"
        key = hashlib.sha1(f"{title}|{event.get('start')}".encode()).hexdigest()[:10]
        out.append(item(f"cal.{key}", "url", title, "日", reason,
                        f"calshow:{int(start.timestamp() - 978307200)}"))
    return out


def retry_rule(job, now):
    """The device's most recent finished job, if it failed in the last 24 h → run it again."""
    if not job or job.get("status") != "failed":
        return []
    finished = parse_time(job.get("updated"))
    if finished is None or now - finished > RETRY_WINDOW:
        return []
    params = {k: v for k, v in (job.get("params") or {}).items() if k != "note"}
    return [item(f"retry.{job['id']}", "capability", f"Retry {job['capability']}", "↻",
                 f"failed {ago(now - finished)}", job["capability"], params)]


def lanes_rule(lanes, catalog):
    """Running lanes from ~/labbox-lanes.json → open the lane (its url, else Boring Box)."""
    box = next((e for e in catalog if e.get("id") == "boringbox"), None)
    out = []
    for lane in lanes:
        state = str(lane.get("status") or lane.get("state") or "").lower()
        if state not in ("running", "active"):
            continue
        name = lane.get("name") or lane.get("lane") or lane.get("id")
        target = lane.get("url") or (box["scheme"] if box else None)
        if not name or not target:
            continue
        out.append(item(f"lane.{slug(name)}", "url", str(name), glyph_of(name), "running", target))
    return out


def time_of_day_rule(taps, now, tz, resolve):
    """Items tapped at least TAP_MIN times within ±1 h of this hour of day (last 30 days),
    most taps first. `resolve(id)` → the item, or None when it is no longer known."""
    hour = now.astimezone(tz).hour
    counts = {}
    for item_id, ts in taps:
        when = parse_time(ts)
        if when is None or now - when > TAP_LOOKBACK:
            continue
        diff = abs(when.astimezone(tz).hour - hour)
        if min(diff, 24 - diff) <= TAP_SLOT_HOURS:
            counts[item_id] = counts.get(item_id, 0) + 1
    out = []
    for item_id, count in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        if count < TAP_MIN:
            continue
        found = resolve(item_id)
        if found:
            out.append({**found, "reason": clip(f"usual {hour:02d}h", REASON_MAX)})
    return out


def fallback_rule(catalog):
    """The catalog in order. No reason: the widget shows nothing under a fallback slot."""
    return [app_item(entry, "") for entry in catalog]


def merge(*groups, limit=MAX_ITEMS):
    seen, out = set(), []
    for group in groups:
        for entry in group:
            if entry["id"] in seen or entry.get("kind") not in KINDS or not ID_RE.match(entry["id"]):
                continue
            seen.add(entry["id"])
            out.append(entry)
            if len(out) == limit:
                return out
    return out


def suggest(now, tz, catalog, taps=(), calendar_result=None, failed_job=None, lanes=(), served=None):
    """Every rule, merged by priority."""
    known = {f"app.{e['id']}": app_item(e, "") for e in catalog}
    # A calendar slot or a retry is about one moment; habit only brings back the lasting kinds.
    known.update({k: v for k, v in (served or {}).items()
                  if isinstance(v, dict) and not k.startswith(("cal.", "retry."))})
    return merge(
        calendar_rule(calendar_result, now),
        retry_rule(failed_job, now),
        lanes_rule(lanes, catalog),
        time_of_day_rule(taps, now, tz, known.get),
        fallback_rule(catalog),
    )


def utc_now():
    return datetime.now(timezone.utc)
