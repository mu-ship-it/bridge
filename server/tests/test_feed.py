"""GET /bridge/feed: the widgets' view of one device — newest jobs, one-line summaries."""
import app as box
import db as store
from conftest import auth


def finish(client, account, job_id, ok=True, result=None, error=None, device="my-iphone"):
    item = {"job_id": job_id, "ok": ok, "finished_at": "2026-10-19T08:00:02Z"}
    if ok:
        item["result"] = result or {}
    else:
        item["error"] = error
    client.post("/bridge/results", headers=auth(account, device),
                json={"device": device, "results": [item]})


def test_feed_requires_a_token_and_a_device(client, account):
    assert client.get("/bridge/feed", params={"device": "my-iphone"}).status_code == 401
    assert client.get("/bridge/feed",
                      headers={"Authorization": f"Bearer {account['token']}"}).status_code == 400


def test_feed_lists_newest_first_with_summaries(client, conn, account):
    with conn:
        info = store.enqueue(conn, account["id"], "my-iphone", "device.info",
                             {"note": "Checking the battery"})
        hr = store.enqueue(conn, account["id"], "my-iphone", "health.query", {"metric": "hr"})
        said = store.enqueue(conn, account["id"], "my-iphone", "agent.say",
                             {"text": "Morning — you slept 7 h", "note": "Narrating"})
        pending = store.enqueue(conn, account["id"], "my-iphone", "location.now")
    client.get("/bridge/jobs", headers=auth(account), params={"device": "my-iphone"})
    finish(client, account, info, result={"battery_level": 0.85, "battery_state": "charging"})
    finish(client, account, hr, result={"count": 25, "metric": {"name": "heart_rate", "data": []}})
    finish(client, account, said, result={"ok": True, "notified": False})

    body = client.get("/bridge/feed", headers=auth(account),
                      params={"device": "my-iphone", "limit": 10}).json()
    assert body["server_time"].endswith("Z")
    assert body["agent_line"] == "Morning — you slept 7 h"
    rows = body["jobs"]
    assert [r["id"] for r in rows] == [pending, said, hr, info]
    assert set(rows[0]) == {"id", "capability", "note", "status", "finished_at", "summary"}
    assert rows[0]["status"] == "running" and rows[0]["finished_at"] is None
    assert rows[0]["summary"] == ""
    assert rows[1]["summary"] == "Morning — you slept 7 h" and rows[1]["note"] == "Narrating"
    assert rows[2]["summary"] == "heart_rate: 25 points" and rows[2]["note"] is None
    assert rows[3] == {"id": info, "capability": "device.info", "note": "Checking the battery",
                       "status": "done", "finished_at": "2026-10-19T08:00:02Z",
                       "summary": "battery 85% charging"}


def test_feed_limit_defaults_caps_and_validates(client, conn, account):
    with conn:
        for _ in range(60):
            store.enqueue(conn, account["id"], "my-iphone", "device.info")
    get = lambda **p: client.get("/bridge/feed", headers=auth(account),
                                 params={"device": "my-iphone", **p})
    assert len(get().json()["jobs"]) == 5
    assert len(get(limit=999).json()["jobs"]) == 50
    assert get(limit=0).status_code == 400
    assert get(limit="x").status_code == 400
    assert get().json()["jobs"][0]["status"] == "queued"


def test_feed_is_scoped_to_the_account_and_device(client, conn, account):
    with conn:
        other_id, other_token = store.create_account(conn, "tenant-b")
        store.enqueue(conn, other_id, "my-iphone", "agent.say", {"text": "not yours"})
        store.enqueue(conn, account["id"], "my-ipad", "agent.say", {"text": "other device"})
    body = client.get("/bridge/feed", headers=auth(account),
                      params={"device": "my-iphone"}).json()
    assert body["jobs"] == [] and body["agent_line"] is None


def test_errors_summarise_as_their_message(client, conn, account):
    with conn:
        job = store.enqueue(conn, account["id"], "my-iphone", "location.now")
    client.get("/bridge/jobs", headers=auth(account), params={"device": "my-iphone"})
    finish(client, account, job, ok=False,
           error={"code": "permission_missing", "message": "Location not requested yet"})
    row = client.get("/bridge/feed", headers=auth(account),
                     params={"device": "my-iphone"}).json()["jobs"][0]
    assert row["status"] == "failed" and row["summary"] == "Location not requested yet"


def test_summary_derivation():
    ok = lambda result: {"ok": True, "result": result}
    assert box.feed_summary("speak", {"text": "hello\n  there"}, ok({"spoken": True})) == "hello there"
    long = box.feed_summary("agent.say", {"text": "x " * 100}, ok({}))
    assert len(long) == 80 and long.endswith("…")
    assert box.feed_summary("device.info", {}, ok({"battery_level": 0.5,
                                                    "battery_state": "unplugged"})) == "battery 50% unplugged"
    assert box.feed_summary("health.query", {"metric": "steps"},
                            ok({"metric": {"name": "step_count", "data": [{}]}})) == "step_count: 1 point"
    assert box.feed_summary("location.now", {}, ok({"lat": 41.8, "lon": 123.4,
                                                     "horizontal_accuracy_m": 35.2})) == "41.8000, 123.4000 ±35 m"
    assert box.feed_summary("reminders.list", {}, ok({"count": 3, "reminders": []})) == "3 items"
    assert box.feed_summary("torch", {}, ok({"on": True})) == "done"
    assert box.feed_summary("torch", {}, {"ok": False, "error": {"code": "foreground_required"}}) \
        == "foreground_required"
    assert box.feed_summary("torch", {}, None) == ""


def test_feed_audits_without_bodies(client, conn, account):
    client.get("/bridge/feed", headers=auth(account), params={"device": "my-iphone"})
    row = conn.execute("SELECT * FROM audit WHERE endpoint = 'GET /bridge/feed'").fetchone()
    assert row["outcome"] == "listed:0"
