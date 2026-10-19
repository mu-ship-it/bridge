"""GET /bridge/suggest and POST /bridge/suggest/tap: the Suggest widget's rules, one by one."""
import json
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

import db as store
import suggest
from conftest import auth

UTC = timezone.utc
NOW = datetime(2026, 10, 19, 8, 30, tzinfo=UTC)
CATALOG = [
    {"id": "wechat", "title": "WeChat", "glyph": "微", "scheme": "weixin://"},
    {"id": "boringbox", "title": "Boring Box", "glyph": "B", "scheme": "https://boringbox.dev/box/"},
]


def iso(dt):
    return dt.isoformat().replace("+00:00", "Z")


@pytest.fixture
def files(tmp_path, monkeypatch):
    """A catalog file and a (missing until written) lanes file, both under tmp."""
    catalog = tmp_path / "suggest.json"
    catalog.write_text(json.dumps({"apps": CATALOG}))
    lanes = tmp_path / "labbox-lanes.json"
    monkeypatch.setenv("BRIDGE_SUGGEST_FILE", str(catalog))
    monkeypatch.setenv("BRIDGE_LANES_FILE", str(lanes))
    return {"catalog": catalog, "lanes": lanes}


# ------------------------------------------------------------------ rules (pure)

def test_calendar_rule_takes_events_in_the_next_two_hours_and_under_way():
    result = {"events": [
        {"title": "Standup", "start": iso(NOW + timedelta(minutes=25)), "end": iso(NOW + timedelta(minutes=40)),
         "all_day": False},
        {"title": "Dentist", "start": iso(NOW - timedelta(minutes=10)), "end": iso(NOW + timedelta(minutes=20)),
         "all_day": False},
        {"title": "Too late", "start": iso(NOW + timedelta(hours=3)), "end": iso(NOW + timedelta(hours=4))},
        {"title": "Birthday", "start": iso(NOW), "end": iso(NOW + timedelta(days=1)), "all_day": True},
        {"title": "Over", "start": iso(NOW - timedelta(hours=2)), "end": iso(NOW - timedelta(hours=1))},
    ]}
    items = suggest.calendar_rule(result, NOW)
    assert [(i["title"], i["reason"]) for i in items] == [("Standup", "in 25m"), ("Dentist", "now")]
    assert items[0]["kind"] == "url" and items[0]["target"].startswith("calshow:")
    assert suggest.calendar_rule(None, NOW) == [] and suggest.calendar_rule({"events": "x"}, NOW) == []


def test_retry_rule_only_for_a_recent_failure():
    failed = {"id": "j_1", "capability": "location.now", "status": "failed",
              "updated": iso(NOW - timedelta(minutes=12)), "params": {"note": "Home?", "accuracy": "best"}}
    [entry] = suggest.retry_rule(failed, NOW)
    assert entry["id"] == "retry.j_1" and entry["kind"] == "capability"
    assert entry["target"] == "location.now" and entry["params"] == {"accuracy": "best"}
    assert entry["reason"] == "failed 12m"
    assert suggest.retry_rule({**failed, "status": "done"}, NOW) == []
    assert suggest.retry_rule({**failed, "updated": iso(NOW - timedelta(days=2))}, NOW) == []
    assert suggest.retry_rule(None, NOW) == []


def test_lanes_rule_takes_running_lanes_only():
    lanes = [{"name": "pll-moss", "status": "running"},
             {"name": "pll-fern", "state": "active", "url": "https://boringbox.dev/box/fern"},
             {"name": "pll-old", "status": "done"}]
    items = suggest.lanes_rule(lanes, CATALOG)
    assert [(i["id"], i["target"]) for i in items] == [
        ("lane.pll-moss", "https://boringbox.dev/box/"), ("lane.pll-fern", "https://boringbox.dev/box/fern")]
    assert all(i["reason"] == "running" for i in items)
    assert suggest.lanes_rule([{"name": "x", "status": "running"}], []) == []   # nowhere to open it


def test_time_of_day_rule_counts_taps_near_this_hour():
    tz = ZoneInfo("Asia/Shanghai")                       # 08:30 UTC = 16:30 there
    local = NOW.astimezone(tz)
    taps = [("app.wechat", iso(local.replace(hour=16) - timedelta(days=d))) for d in (1, 2, 3)]
    taps += [("app.boringbox", iso(local.replace(hour=17) - timedelta(days=1)))]          # only once
    taps += [("app.boringbox", iso(local.replace(hour=9) - timedelta(days=d))) for d in (1, 2)]  # other slot
    taps += [("app.gone", iso(local.replace(hour=16) - timedelta(days=d))) for d in (1, 2)]   # unknown id
    taps += [("app.wechat", iso(NOW - timedelta(days=40)))] * 5                            # too old
    known = {"app.wechat": suggest.app_item(CATALOG[0], "app")}
    items = suggest.time_of_day_rule(taps, NOW, tz, known.get)
    assert [(i["id"], i["reason"]) for i in items] == [("app.wechat", "usual 16h")]


def test_time_of_day_slot_wraps_round_midnight():
    now = datetime(2026, 10, 19, 23, 30, tzinfo=UTC)
    taps = [("app.wechat", iso(now.replace(hour=0) - timedelta(days=d))) for d in (1, 2)]
    known = {"app.wechat": suggest.app_item(CATALOG[0], "app")}
    assert [i["id"] for i in suggest.time_of_day_rule(taps, now, UTC, known.get)] == ["app.wechat"]


def test_fallback_and_merge_priority_dedupe_and_cap():
    items = suggest.suggest(
        NOW, UTC, CATALOG + [{"id": f"a{n}", "title": f"App {n}", "scheme": f"a{n}://"} for n in range(6)],
        calendar_result={"events": [{"title": "Standup", "start": iso(NOW + timedelta(minutes=5)),
                                     "end": iso(NOW + timedelta(minutes=20))}]},
        failed_job={"id": "j_9", "capability": "device.info", "status": "failed", "updated": iso(NOW)},
        lanes=[{"name": "pll-moss", "status": "running"}],
        taps=[("app.boringbox", iso(NOW - timedelta(days=d))) for d in (1, 2)],
    )
    assert len(items) == suggest.MAX_ITEMS
    assert [i["id"].split(".")[0] for i in items[:4]] == ["cal", "retry", "lane", "app"]
    assert items[3]["id"] == "app.boringbox" and items[3]["reason"] == "usual 08h"
    assert [i["id"] for i in items[4:]] == ["app.wechat", "app.a0"]       # boringbox not repeated
    for i in items:
        assert 1 <= len(i["glyph"]) <= 2 and len(i["reason"]) <= suggest.REASON_MAX
        assert suggest.ID_RE.match(i["id"])


def test_reason_and_title_are_clipped():
    entry = suggest.item("x", "url", "t" * 100, "XYZ", "a reason that is far too long", "https://x")
    assert len(entry["reason"]) == suggest.REASON_MAX and entry["reason"].endswith("…")
    assert len(entry["title"]) == suggest.TITLE_MAX and entry["glyph"] == "XY"


def test_catalog_falls_back_to_the_committed_example(tmp_path, monkeypatch):
    monkeypatch.setenv("BRIDGE_SUGGEST_FILE", str(tmp_path / "missing.json"))
    ids = [e["id"] for e in suggest.load_catalog()]
    assert ids == ["wechat", "alipay", "telegram", "rednote", "safari", "boringbox", "camera"]
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps([{"id": "ok", "title": "OK", "scheme": "ok://"}, {"id": "no scheme", "title": "x"}]))
    assert [e["id"] for e in suggest.load_catalog(bad)] == ["ok"]


def test_lanes_file_missing_or_malformed_is_empty(tmp_path):
    assert suggest.load_lanes(tmp_path / "none.json") == []
    broken = tmp_path / "broken.json"
    broken.write_text("{nope")
    assert suggest.load_lanes(broken) == []
    good = tmp_path / "lanes.json"
    good.write_text(json.dumps({"lanes": [{"name": "a", "status": "running"}, "junk"]}))
    assert suggest.load_lanes(good) == [{"name": "a", "status": "running"}]


# ------------------------------------------------------------------ endpoints

def test_suggest_requires_a_token_a_device_and_a_valid_tz(client, account, files):
    assert client.get("/bridge/suggest", params={"device": "my-iphone"}).status_code == 401
    assert client.get("/bridge/suggest",
                      headers={"Authorization": f"Bearer {account['token']}"}).status_code == 400
    r = client.get("/bridge/suggest", headers=auth(account), params={"device": "my-iphone", "tz": "Mars/Base"})
    assert r.status_code == 400


def test_suggest_fallback_is_the_catalog(client, account, files):
    body = client.get("/bridge/suggest", headers=auth(account), params={"device": "my-iphone"}).json()
    assert body["generated_at"].endswith("Z")
    assert [i["id"] for i in body["items"]] == ["app.wechat", "app.boringbox"]
    assert body["items"][0] == {"id": "app.wechat", "kind": "app", "title": "WeChat", "glyph": "微",
                                "reason": "app", "target": "weixin://"}


def test_suggest_uses_calendar_failed_job_and_lanes(client, conn, account, files):
    soon = datetime.now(UTC) + timedelta(minutes=30)
    with conn:
        cal = store.enqueue(conn, account["id"], "my-iphone", "calendar.events")
        loc = store.enqueue(conn, account["id"], "my-iphone", "location.now", {"note": "Home?"})
    client.get("/bridge/jobs", headers=auth(account), params={"device": "my-iphone"})
    client.post("/bridge/results", headers=auth(account), json={"device": "my-iphone", "results": [
        {"job_id": cal, "ok": True, "result": {"events": [
            {"title": "Standup", "start": iso(soon), "end": iso(soon + timedelta(minutes=15)), "all_day": False}]}},
    ]})
    client.post("/bridge/results", headers=auth(account), json={"device": "my-iphone", "results": [
        {"job_id": loc, "ok": False, "error": {"code": "permission_denied", "message": "no"}},
    ]})
    files["lanes"].write_text(json.dumps([{"name": "pll-moss", "status": "running"}]))

    items = client.get("/bridge/suggest", headers=auth(account), params={"device": "my-iphone"}).json()["items"]
    assert [i["kind"] for i in items[:3]] == ["url", "capability", "url"]
    assert items[0]["title"] == "Standup"
    assert items[1] == {"id": f"retry.{loc}", "kind": "capability", "title": "Retry location.now", "glyph": "↻",
                        "reason": "failed 0m", "target": "location.now", "params": {}}
    assert items[2]["id"] == "lane.pll-moss"


def test_taps_are_logged_audited_and_feed_time_of_day(client, conn, account, files):
    assert client.post("/bridge/suggest/tap", json={"device": "my-iphone", "id": "app.boringbox"}).status_code == 401
    r = client.post("/bridge/suggest/tap", headers=auth(account), json={"device": "my-iphone", "id": "bad id/"})
    assert r.status_code == 400
    for _ in range(2):
        r = client.post("/bridge/suggest/tap", headers=auth(account), json={"device": "my-iphone", "id": "app.boringbox"})
        assert r.json() == {"ok": True}
    outcomes = [row["outcome"] for row in store.audit_tail(conn, account["id"], "my-iphone")]
    assert outcomes.count("tapped") == 2 and "bad_request:id" in outcomes

    items = client.get("/bridge/suggest", headers=auth(account), params={"device": "my-iphone"}).json()["items"]
    assert items[0]["id"] == "app.boringbox" and items[0]["reason"].startswith("usual ")


def test_a_served_item_resolves_after_its_rule_stops_producing_it(client, conn, account, files):
    files["lanes"].write_text(json.dumps([{"name": "pll-moss", "status": "running"}]))
    client.get("/bridge/suggest", headers=auth(account), params={"device": "my-iphone"})
    for _ in range(2):
        client.post("/bridge/suggest/tap", headers=auth(account), json={"device": "my-iphone", "id": "lane.pll-moss"})
    files["lanes"].write_text("[]")
    items = client.get("/bridge/suggest", headers=auth(account), params={"device": "my-iphone"}).json()["items"]
    assert items[0]["id"] == "lane.pll-moss" and items[0]["reason"].startswith("usual ")


def test_taps_and_served_items_are_per_device_and_purged(client, conn, account, files):
    for _ in range(2):
        client.post("/bridge/suggest/tap", headers=auth(account), json={"device": "my-iphone", "id": "app.boringbox"})
    other = client.get("/bridge/suggest", headers=auth(account, "my-ipad"), params={"device": "my-ipad"}).json()
    assert other["items"][0]["id"] == "app.wechat"
    counts = store.purge_device(conn, account["id"], "my-iphone")
    assert counts["suggest_taps"] == 2
