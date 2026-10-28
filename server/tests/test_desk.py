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
    assert over["title"] == "red" and over["text"] == "140m / 98m" and over["level"] == "warn"
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


# ------------------------------------------------------------------ room

def test_room_keeps_the_latest_report_and_the_desk_serves_it(client, account):
    empty = client.get("/bridge/board/desk", headers=bearer(account)).json()["room"]
    assert empty == {"temp_c": None, "humidity": None, "source": None, "age_s": None, "stale": False}
    for body in ({"source": "study", "temp_c": 22.0, "humidity": 50}, {"source": "study", "temp_c": 23.4, "humidity": None}):
        assert client.post("/bridge/room", headers=bearer(account), json=body).status_code == 200
    room = client.get("/bridge/board/desk", headers=bearer(account)).json()["room"]
    assert room["temp_c"] == 23.4 and room["humidity"] is None and room["source"] == "study"
    assert room["stale"] is False and room["age_s"] < 5


@pytest.mark.parametrize("body", [
    {}, {"source": "Bad Source", "temp_c": 20}, {"source": "study", "temp_c": "hot"},
    {"source": "study", "temp_c": True}, {"source": "study", "humidity": 101}, {"source": "study", "temp_c": 999},
])
def test_bad_room_is_a_400(client, account, body):
    assert client.post("/bridge/room", headers=bearer(account), json=body).status_code == 400


def test_room_needs_a_token(client):
    assert client.post("/bridge/room", json={"source": "study", "temp_c": 20}).status_code == 401


def test_room_goes_stale_after_fifteen_minutes():
    def report(minutes):
        received = (NOW - timedelta(minutes=minutes)).isoformat().replace("+00:00", "Z")
        return [{"source": "study", "temp_c": 21.0, "humidity": 40.0, "received": received}]
    assert desk.summarize_room(report(14), NOW)["stale"] is False
    assert desk.summarize_room(report(16), NOW)["stale"] is True


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


# ------------------------------------------------------------------ seats and activity

def _kit(name):
    import json
    from pathlib import Path
    return json.loads((Path(__file__).parent / "fixtures" / name).read_text(encoding="utf-8"))


def test_seats_are_the_usage_rows_of_the_muster_board():
    board = _kit("muster-sample.json")["board"]
    seats = desk.compose_seats([("muster", board, "2026-10-28T05:37:26Z")])
    assert [(s["name"], s["pct"]) for s in seats] == [("Max", 26), ("Team", 4)]
    assert seats[0]["detail"] == "resets Tue 08:00"
    assert desk.compose_seats([]) == [] and desk.compose_seats([("other", board, "x")]) == []


def test_activity_sums_todays_steps_and_leaves_missing_rings_null():
    activity = desk.parse_activity(_kit("health-sample.json"))
    assert activity == {"move_pct": None, "exercise_pct": None, "stand_pct": None, "steps": 871}
    assert desk.parse_activity(None)["steps"] is None


def test_activity_rings_are_percent_of_the_goals():
    day = "2026-10-28 09:00:00 +0800"
    export = {"data": {"metrics": [
        {"name": "active_energy", "units": "kcal", "data": [{"date": day, "qty": 250}, {"date": day, "qty": 50}]},
        {"name": "apple_exercise_time", "units": "min", "data": [{"date": day, "qty": 45}]},
        {"name": "apple_stand_hour", "units": "hr", "data": [{"date": day, "qty": 6}]},
        {"name": "step_count", "units": "count", "data": [{"date": day, "qty": 6214}]},
    ]}}
    assert desk.parse_activity(export) == {"move_pct": 60, "exercise_pct": 150, "stand_pct": 50, "steps": 6214}


def test_desk_payload_carries_seats_and_activity(client, account, monkeypatch, tmp_path):
    import shutil
    from pathlib import Path
    shutil.copy(Path(__file__).parent / "fixtures" / "health-sample.json", tmp_path / "2026-10-28.json")
    monkeypatch.setattr(desk.config, "get", lambda key, _get=desk.config.get: str(tmp_path) if key == "BRIDGE_HEALTH_DIR" else _get(key))
    board = _kit("muster-sample.json")["board"]
    assert client.post("/bridge/board/muster", headers=bearer(account), json=board).status_code == 200
    body = client.get("/bridge/board/desk", headers=bearer(account)).json()
    assert [(s["name"], s["pct"]) for s in body["seats"]] == [("Max", 26), ("Team", 4)]
    assert body["activity"]["steps"] == 871 and body["activity"]["move_pct"] is None


# ------------------------------------------------------------------ progress

NOW = datetime(2026, 10, 28, 12, 0, tzinfo=timezone.utc)


def report(state="running", age_s=0, **over):
    received = desk.iso(NOW - timedelta(seconds=age_s))
    return {"source": "indexer", "title": "文件索引", "done": 6400.0, "total": 11268.0, "unit": "files",
            "eta": "04:10", "state": state, "note": "images 2,100/5,632", "received": received, **over}


def test_a_running_progress_row_follows_the_events():
    events = [event("e_1", "notify", "hi")]
    items = desk.compose_attention(events, [], [], [report()], NOW)
    assert items[0]["kind"] != "progress"
    row = items[-1]
    assert row["kind"] == "progress" and row["id"] == "progress:indexer" and row["pct"] == 57
    assert (row["title"], row["done"], row["total"], row["eta"], row["state"]) == ("文件索引", 6400.0, 11268.0, "04:10", "running")
    assert row["note"] == "images 2,100/5,632" and len(items) == 2


def test_a_done_progress_row_expires_and_a_stale_running_one_drops():
    assert desk.compose_attention([], [], [], [report("done", age_s=300, done=11268.0)], NOW)[0]["pct"] == 100
    assert desk.compose_attention([], [], [], [report("done", age_s=601)], NOW) == []
    assert desk.compose_attention([], [], [], [report(age_s=29 * 60)], NOW) != []
    assert desk.compose_attention([], [], [], [report(age_s=31 * 60)], NOW) == []


def test_a_failed_progress_row_stays_until_acked():
    failed = report("failed", age_s=3 * 3600)
    assert len(desk.compose_attention([], [], [], [failed], NOW)) == 1
    ack = event("e_9", "attention.ack", payload={"ids": ["progress:indexer"]})
    assert desk.compose_attention([], [ack], [], [failed], NOW) == []


def test_progress_is_posted_and_served_on_the_desk(client, account):
    body = {"source": "indexer", "title": "文件索引", "done": 6400, "total": 11268, "unit": "files",
            "eta": "04:10", "state": "running", "note": "images 2,100/5,632"}
    assert client.post("/bridge/progress", headers=bearer(account), json=body).status_code == 200
    client.post("/bridge/progress", headers=bearer(account), json={**body, "done": 7000})
    rows = [i for i in client.get("/bridge/board/desk", headers=bearer(account)).json()["attention"] if i["kind"] == "progress"]
    assert len(rows) == 1 and rows[0]["done"] == 7000 and rows[0]["pct"] == 62


@pytest.mark.parametrize("body", [
    {}, {"source": "Bad", "title": "x", "done": 1}, {"source": "a", "done": 1}, {"source": "a", "title": "x", "done": -1},
    {"source": "a", "title": "x", "done": 1, "state": "paused"}, {"source": "a", "title": "x", "done": True},
])
def test_bad_progress_is_a_400(client, account, body):
    assert client.post("/bridge/progress", headers=bearer(account), json=body).status_code == 400


def test_progress_needs_a_token(client):
    assert client.post("/bridge/progress", json={"source": "a", "title": "x", "done": 1}).status_code == 401


def test_attention_titles_are_clipped_to_eight_wide_cjk_counting_two(caplog):
    with caplog.at_level("WARNING", logger="bridge.desk"):
        assert desk.clip_title("Google Drive", "fileindex") == "Google D"   # 8 Latin
        assert desk.clip_title("谷歌云端硬盘") == "谷歌云端"                                # 4 CJK = 8
        assert desk.clip_title("索引 ok") == "索引 ok"                                      # 2+2+1+... fits
        assert desk.clip_title("Drive") == "Drive"
    assert "fileindex" in caplog.text and "clipped" in caplog.text
    assert len(caplog.records) == 2        # only the two that were cut are logged


def test_progress_and_event_titles_reach_the_desk_clipped(client, account):
    r = client.post("/bridge/progress", headers=bearer(account),
                    json={"source": "gdrive", "title": "Google Drive download", "done": 1, "total": 2})
    assert r.status_code == 200
    items = client.get("/bridge/board/desk", headers=bearer(account)).json()["attention"]
    assert [i["title"] for i in items if i["kind"] == "progress"] == ["Google D"]
