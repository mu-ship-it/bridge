"""Device-originated events (POST/GET /bridge/events), duty heartbeats, and their CLI."""
from datetime import datetime, timedelta, timezone

import cli
import db as store
from conftest import auth


def heartbeat(duty=True, ts="2026-10-17T09:00:00Z"):
    return {"type": "heartbeat", "ts": ts, "note": "Duty-mode heartbeat",
            "payload": {"duty": duty, "battery_level": 0.98, "app_version": "0.4.0 (1)"}}


def test_one_event_is_stored_and_read_back_by_the_agent(client, account):
    event = {"type": "speech", "ts": "2026-10-17T09:00:05+02:00", "note": "Heard in the kitchen",
             "payload": {"text": "turn the lights off", "start": 0.0, "end": 1.8, "locale": "en-US"}}
    response = client.post("/bridge/events", headers=auth(account, "my-ipad"), json=event)
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True and body["stored"] == 1 and body["ids"][0].startswith("e_")

    listed = client.get("/bridge/events", headers={"Authorization": f"Bearer {account['token']}"}).json()
    [got] = listed["events"]
    assert got["device"] == "my-ipad" and got["type"] == "speech"
    assert got["ts"] == "2026-10-17T07:00:05Z"            # normalised to UTC
    assert got["payload"]["text"] == "turn the lights off" and got["note"] == "Heard in the kitchen"
    assert listed["next"] == got["id"]


def test_a_batch_is_all_or_nothing(client, conn, account):
    good = {"type": "speech", "note": "n", "payload": {"text": "a"}}
    response = client.post("/bridge/events", headers=auth(account),
                           json={"events": [good, {"type": "speech", "payload": {}}]})
    assert response.status_code == 400 and "note" in response.json()["error"]
    assert store.list_events(conn, account["id"]) == []
    assert client.post("/bridge/events", headers=auth(account),
                       json={"events": [good, good]}).json()["stored"] == 2


def test_bad_events_are_400s(client, account):
    cases = [
        {"type": "Speech!", "note": "n"},
        {"type": "speech"},                                   # no note
        {"type": "speech", "note": "   "},
        {"type": "speech", "note": "n", "payload": [1, 2]},
        {"type": "speech", "note": "n", "ts": "yesterday"},
        {"type": "speech", "note": "n", "ts": "2026-10-17T09:00:00"},   # no timezone
        {"type": "speech", "note": "n", "payload": {"text": "x" * 70_000}},
        {"events": []},
        {"events": [{"type": "speech", "note": "n"}] * 101},
    ]
    for body in cases:
        assert client.post("/bridge/events", headers=auth(account), json=body).status_code == 400, body


def test_events_are_filtered_by_device_type_and_since(client, account):
    h = auth(account, "my-ipad")
    first = client.post("/bridge/events", headers=h, json=heartbeat()).json()["ids"][0]
    client.post("/bridge/events", headers=h, json={"type": "speech", "note": "n", "payload": {"text": "hi"}})
    client.post("/bridge/events", headers=auth(account, "my-iphone"), json={"type": "speech", "note": "n"})
    bare = {"Authorization": f"Bearer {account['token']}"}

    def ids(**params):
        return [e["type"] + "@" + e["device"] for e in
                client.get("/bridge/events", headers=bare, params=params).json()["events"]]

    assert ids() == ["heartbeat@my-ipad", "speech@my-ipad", "speech@my-iphone"]
    assert ids(device="my-ipad") == ["heartbeat@my-ipad", "speech@my-ipad"]
    assert ids(type="speech") == ["speech@my-ipad", "speech@my-iphone"]
    assert ids(since=first) == ["speech@my-ipad", "speech@my-iphone"]
    assert ids(since="2000-01-01T00:00:00Z", limit=1) == ["heartbeat@my-ipad"]
    assert ids(since="2999-01-01T00:00:00Z") == []
    assert client.get("/bridge/events", headers=bare, params={"limit": "x"}).status_code == 400
    assert client.get("/bridge/events", headers=bare, params={"since": "soon"}).status_code == 400


def test_one_tenant_never_sees_another_tenants_events(client, account, other_account):
    client.post("/bridge/events", headers=auth(account), json={"type": "speech", "note": "secret"})
    assert client.get("/bridge/events", headers=auth(other_account)).json()["events"] == []
    assert client.post("/bridge/events", json={"type": "speech", "note": "n"},
                       headers={"X-Bridge-Device": "my-iphone"}).status_code == 401


def test_a_heartbeat_puts_duty_and_last_seen_on_the_device_record(client, conn, account):
    client.post("/bridge/events", headers=auth(account, "my-ipad"), json=heartbeat(duty=True))
    row = store.get_device(conn, account["id"], "my-ipad")
    d = store.device_dict(row, now=datetime(2026, 10, 17, 9, 4, tzinfo=timezone.utc))
    assert d["duty"] is True and d["duty_stale"] is False and d["last_seen"] is not None
    assert d["heartbeat_at"] == "2026-10-17T09:00:00Z" and d["app_version"] == "0.4.0 (1)"
    # Two missed beats: the box stops trusting the claim.
    later = datetime(2026, 10, 17, 9, 0, tzinfo=timezone.utc) + timedelta(minutes=11)
    assert store.device_dict(row, now=later)["duty_stale"] is True

    client.post("/bridge/events", headers=auth(account, "my-ipad"),
                json=heartbeat(duty=False, ts="2026-10-17T09:05:00Z"))
    d = store.device_dict(store.get_device(conn, account["id"], "my-ipad"), now=later)
    assert d["duty"] is False and d["duty_stale"] is False


def test_events_are_audited_by_type_and_count_never_by_content(client, conn, account):
    client.post("/bridge/events", headers=auth(account), json={"events": [
        {"type": "speech", "note": "n", "payload": {"text": "my pin is 4711"}}, heartbeat()]})
    client.get("/bridge/events", headers=auth(account))
    seen = [(r["endpoint"], r["outcome"]) for r in store.audit_tail(conn, limit=10)]
    assert ("POST /bridge/events", "stored:heartbeat=1,speech=1") in seen
    assert ("GET /bridge/events", "listed:2") in seen
    blob = " ".join(str(tuple(r)) for r in store.audit_tail(conn, limit=10))
    assert "4711" not in blob


def test_purge_erases_a_devices_events(conn, account):
    with conn:
        store.add_event(conn, account["id"], "my-ipad", "speech", store.now_iso(), "n", {"text": "x"})
    assert store.purge_device(conn, account["id"], "my-ipad")["events"] == 1
    assert store.list_events(conn, account["id"]) == []


def test_cli_devices_shows_duty_and_events_lists_them(client, db_path, conn, account, capsys):
    now = store.now_iso()
    client.post("/bridge/events", headers=auth(account, "my-ipad"), json=heartbeat(ts=now))
    client.post("/bridge/events", headers=auth(account, "my-ipad"),
                json={"type": "speech", "note": "Mu, at the desk", "payload": {"text": "hello"}})
    capsys.readouterr()

    cli.main(["devices", "--account", "tenant-a"])
    out = capsys.readouterr().out
    assert "my-ipad" in out and f"duty on(beat {now})" in out and "last_seen" in out

    cli.main(["events", "tenant-a", "--type", "speech"])
    out = capsys.readouterr().out
    assert "speech" in out and "Mu, at the desk" in out and "hello" in out and "heartbeat" not in out

    cli.main(["events", "tenant-a", "--json", "--device", "my-ipad"])
    import json
    assert [e["type"] for e in json.loads(capsys.readouterr().out)] == ["heartbeat", "speech"]
