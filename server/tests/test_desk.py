"""The desk display (v0.6): POST /bridge/presence, GET /bridge/board/desk, and desk.py's pieces."""
from datetime import datetime, timedelta, timezone

import pytest

import app as app_module
import db as store
import desk
from conftest import auth

NOW = datetime(2026, 10, 27, 9, 0, 0, tzinfo=timezone.utc)

OPEN_METEO = {
    "current": {"temperature_2m": 6.4, "relative_humidity_2m": 61, "apparent_temperature": 3.9,
                "weather_code": 3, "wind_speed_10m": 12.2, "is_day": 1},
    "daily": {"temperature_2m_max": [9.1], "temperature_2m_min": [-1.5],
              "precipitation_probability_max": [10]},
}


def bearer(account):
    return {"Authorization": f"Bearer {account['token']}"}


@pytest.fixture(autouse=True)
def fake_weather(monkeypatch):
    calls = []

    def fetch(lat, lon):
        calls.append((lat, lon))
        return OPEN_METEO

    monkeypatch.setattr(desk, "weather_cache", desk.WeatherCache(fetch=fetch))
    return calls


# ------------------------------------------------------------------ presence

def test_presence_keeps_the_latest_report_per_source(client, conn, account):
    for active, idle in ((True, 3), (False, 400)):
        response = client.post("/bridge/presence", headers=bearer(account),
                               json={"source": "pc", "active": active, "idle_s": idle})
        assert response.status_code == 200 and response.json() == {"ok": True, "source": "pc"}
    client.post("/bridge/presence", headers=bearer(account), json={"source": "mac", "active": True, "idle_s": 0})
    reports = {r["source"]: r for r in store.list_presence(conn, account["id"])}
    assert set(reports) == {"pc", "mac"}
    assert reports["pc"]["active"] is False and reports["pc"]["idle_s"] == 400


@pytest.mark.parametrize("body", [
    {"active": True, "idle_s": 1},
    {"source": "PC!", "active": True},
    {"source": "pc", "active": "yes"},
    {"source": "pc", "active": True, "idle_s": -1},
    {"source": "pc", "active": True, "idle_s": True},
])
def test_bad_presence_is_a_400(client, account, body):
    assert client.post("/bridge/presence", headers=bearer(account), json=body).status_code == 400


def test_presence_needs_a_token(client):
    assert client.post("/bridge/presence", json={"source": "pc", "active": True}).status_code == 401


def test_presence_summary_counts_only_fresh_active_sources():
    old = desk.iso(NOW - timedelta(seconds=200))
    fresh = desk.iso(NOW - timedelta(seconds=20))
    away = desk.summarize_presence([{"source": "pc", "active": True, "idle_s": 1, "received": old}], NOW)
    assert away["present"] is False and away["age_s"] == 200 and away["sources"][0]["fresh"] is False
    idle = desk.summarize_presence([{"source": "pc", "active": False, "idle_s": 300, "received": fresh}], NOW)
    assert idle["present"] is False and idle["idle_s"] == 300
    here = desk.summarize_presence([
        {"source": "mac", "active": False, "idle_s": 900, "received": fresh},
        {"source": "pc", "active": True, "idle_s": 2, "received": desk.iso(NOW - timedelta(seconds=40))},
    ], NOW)
    assert here["present"] is True and here["source"] == "pc" and here["age_s"] == 40
    nobody = desk.summarize_presence([], NOW)
    assert nobody["present"] is False and nobody["source"] is None and nobody["stale_after_s"] == 90


# ------------------------------------------------------------------ weather

def test_weather_is_parsed_and_cached_for_15_minutes():
    clock = [1_000_000.0]
    calls = []

    def fetch(lat, lon):
        calls.append((lat, lon))
        return OPEN_METEO

    cache = desk.WeatherCache(fetch=fetch, clock=lambda: clock[0])
    first = cache.get(41.80, 123.43, "Shenyang")
    assert first["temp_c"] == 6.4 and first["humidity"] == 61 and first["code"] == 3
    assert first["high_c"] == 9.1 and first["low_c"] == -1.5 and first["place"] == "Shenyang"
    assert first["stale"] is False and first["age_s"] == 0
    clock[0] += 14 * 60
    assert cache.get(41.80, 123.43)["age_s"] == 14 * 60 and len(calls) == 1
    clock[0] += 60
    assert cache.get(41.80, 123.43)["age_s"] == 0 and len(calls) == 2


def test_a_failed_fetch_serves_the_last_answer_marked_stale_or_nothing():
    clock = [0.0]
    answers = [OPEN_METEO]

    def fetch(lat, lon):
        if not answers:
            raise OSError("offline")
        return answers.pop()

    cache = desk.WeatherCache(fetch=fetch, clock=lambda: clock[0])
    cache.get(1.0, 2.0)
    clock[0] += 20 * 60
    stale = cache.get(1.0, 2.0)
    assert stale["stale"] is True and stale["temp_c"] == 6.4 and stale["age_s"] == 20 * 60
    assert desk.WeatherCache(fetch=fetch).get(3.0, 4.0) is None


def test_open_meteo_without_a_temperature_is_rejected():
    with pytest.raises(ValueError):
        desk.parse_open_meteo({"current": {"weather_code": 1}})


# ------------------------------------------------------------------ attention

def event(id, type, note="n", payload=None, received="2026-10-27T08:00:00Z"):
    return {"id": id, "device": "pc", "type": type, "ts": received, "received": received,
            "note": note, "payload": payload}


def test_attention_merges_events_and_board_rows_newest_first_minus_acks():
    events = [
        event("e_1", "notify", "Build finished", received="2026-10-27T07:00:00Z"),
        event("e_2", "alert", "Disk 92 %", {"speak": True, "title": "lab box"}, received="2026-10-27T08:30:00Z"),
        event("e_3", "agent.say", "ignored note", {"text": "Lunch?"}, received="2026-10-27T08:00:00Z"),
    ]
    boards = [("muster", {"title": "Lanes", "sections": [{"title": "L", "rows": [
        {"label": "red", "state": "over", "value": "140m / 98m"},
        {"label": "cyan", "state": "ok"},
        {"label": "teal", "state": "stalled", "detail": "no output"},
    ]}]}, "2026-10-27T08:45:00Z")]
    acks = [event("e_9", "attention.ack", payload={"ids": ["e_1", 7]})]
    items = desk.compose_attention(events, acks, boards)
    assert [i["kind"] for i in items] == ["board.over", "board.stalled", "alert", "agent.say"]
    over, stalled, alert, said = items
    assert over["title"] == "Lanes · red" and over["text"] == "140m / 98m" and over["level"] == "warn"
    assert stalled["level"] == "info" and stalled["text"] == "no output"
    assert alert["speak"] is True and alert["title"] == "lab box" and alert["level"] == "warn"
    assert said["text"] == "Lunch?" and said["speak"] is False and said["level"] == "info"
    assert over["id"] == desk.board_row_id("muster", "red")

    acked = desk.compose_attention(events, acks + [event("e_10", "attention.ack", payload={"ids": [over["id"]]})], boards)
    assert over["id"] not in [i["id"] for i in acked]


def test_attention_is_capped_and_texts_clipped():
    events = [event(f"e_{n:03}", "notify", "x" * 500) for n in range(30)]
    items = desk.compose_attention(events, [], [])
    assert len(items) == desk.ATTENTION_MAX and len(items[0]["text"]) == desk.ATTENTION_TEXT_MAX


# ------------------------------------------------------------------ the endpoint

def test_desk_composes_time_weather_attention_and_presence(client, conn, account, fake_weather):
    client.post("/bridge/events", headers=auth(account, "pc"),
                json={"events": [{"type": "alert", "note": "Backup failed", "payload": {"speak": True}},
                                 {"type": "speech", "note": "not for the desk"}]})
    client.post("/bridge/board/muster", headers=bearer(account),
                json={"title": "Lanes", "sections": [{"title": "L", "rows": [{"label": "red", "state": "over"}]}]})
    client.post("/bridge/presence", headers=bearer(account), json={"source": "pc", "active": True, "idle_s": 4})

    response = client.get("/bridge/board/desk?tz=Asia/Shanghai", headers=auth(account, "desk-mini"))
    assert response.status_code == 200
    body = response.json()
    assert body["time"]["tz"] == "Asia/Shanghai" and body["time"]["utc_offset_s"] == 8 * 3600
    assert body["time"]["now"].endswith("Z")
    assert body["weather"]["temp_c"] == 6.4 and body["weather"]["place"] == "Shenyang"
    assert fake_weather == [(41.80, 123.43)]
    kinds = {i["kind"]: i for i in body["attention"]}                # same second: order is a tie
    assert set(kinds) == {"board.over", "alert"} and kinds["alert"]["speak"] is True
    assert body["presence"]["present"] is True and body["presence"]["source"] == "pc"

    alert_id = kinds["alert"]["id"]
    client.post("/bridge/events", headers=auth(account, "desk-mini"),
                json={"type": "attention.ack", "note": "Acknowledged on the desk", "payload": {"ids": [alert_id]}})
    again = client.get("/bridge/board/desk", headers=auth(account, "desk-mini")).json()
    assert [i["kind"] for i in again["attention"]] == ["board.over"]
    assert len(fake_weather) == 1                                    # cached


def test_desk_leaves_out_events_older_than_a_day(client, conn, account):
    with conn:
        old = store.add_event(conn, account["id"], "pc", "notify", "2026-10-01T00:00:00Z", "old")
        conn.execute("UPDATE events SET received = ? WHERE id = ?", ("2026-10-01T00:00:00Z", old))
    assert client.get("/bridge/board/desk", headers=bearer(account)).json()["attention"] == []


def test_desk_without_weather_still_answers(client, account, monkeypatch):
    def offline(lat, lon):
        raise OSError("offline")
    monkeypatch.setattr(desk, "weather_cache", desk.WeatherCache(fetch=offline))
    body = client.get("/bridge/board/desk", headers=bearer(account)).json()
    assert body["weather"] is None and body["attention"] == [] and body["presence"]["present"] is False


def test_desk_is_scoped_to_the_account(client, account, other_account):
    client.post("/bridge/events", headers=auth(other_account, "pc"), json={"type": "alert", "note": "theirs"})
    client.post("/bridge/presence", headers=bearer(other_account), json={"source": "pc", "active": True})
    body = client.get("/bridge/board/desk", headers=bearer(account)).json()
    assert body["attention"] == [] and body["presence"]["sources"] == []


def test_desk_needs_a_token_and_a_real_tz(client, account):
    assert client.get("/bridge/board/desk").status_code == 401
    assert client.get("/bridge/board/desk?tz=Mars/Base", headers=bearer(account)).status_code == 400


def test_the_desk_board_name_is_reserved(client, account):
    response = client.post("/bridge/board/desk", headers=bearer(account),
                           json={"title": "x", "sections": []})
    assert response.status_code == 400 and "reserved" in response.json()["error"]
