"""HTTP contract: docs/API.md, exactly — plus the tenancy and audit rules around it."""
import time

import db as store
from conftest import auth


def test_health_needs_no_token(client):
    response = client.get("/bridge/health")
    assert response.status_code == 200 and response.json()["ok"] is True


def test_ping_requires_a_live_token(client, conn, account):
    assert client.get("/bridge/ping", params={"device": "my-iphone"}).status_code == 401
    assert client.get("/bridge/ping", headers={"Authorization": "Bearer brg_wrong"},
                      params={"device": "my-iphone"}).status_code == 401
    assert client.get("/bridge/ping", headers={"Authorization": account["token"]},
                      params={"device": "my-iphone"}).status_code == 401  # no "Bearer "

    response = client.get("/bridge/ping", headers=auth(account), params={"device": "my-iphone"})
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True and body["server_time"].endswith("Z")

    with conn:
        store.revoke_account(conn, "tenant-a")
    assert client.get("/bridge/ping", headers=auth(account),
                      params={"device": "my-iphone"}).status_code == 401


def test_the_401_body_is_ours_not_the_site_sso(client):
    assert client.get("/bridge/ping").json() == {"error": "unauthorized"}


def test_ping_records_the_device_without_registration(client, conn, account):
    client.get("/bridge/ping", headers=auth(account), params={"device": "my-iphone"})
    assert store.get_device(conn, account["id"], "my-iphone")["last_seen"] is not None


def test_device_registration_keeps_the_latest_apns_token(client, conn, account):
    body = {"device": "my-iphone", "apns_token": "a" * 64, "apns_environment": "development",
            "app_version": "0.1.0 (1)",
            "capabilities": ["device.info", "health.query", "location.now"]}
    assert client.post("/bridge/devices", headers=auth(account), json=body).status_code == 200
    body["apns_token"] = "b" * 64
    assert client.post("/bridge/devices", headers=auth(account), json=body).status_code == 200
    row = store.get_device(conn, account["id"], "my-iphone")
    assert row["apns_token"] == "b" * 64
    meta = store.unjson(row["meta"])
    assert meta["capabilities"] == ["device.info", "health.query", "location.now"]
    assert meta["apns_environment"] == "development"


def test_a_call_without_a_device_id_is_a_400(client, account):
    response = client.post("/bridge/devices", headers={"Authorization":
                                                       f"Bearer {account['token']}"}, json={})
    assert response.status_code == 400 and "device" in response.json()["error"]


def test_jobs_returns_the_documented_shape_and_leases(client, conn, account):
    with conn:
        info_id = store.enqueue(conn, account["id"], "my-iphone", "device.info")
        hrv_id = store.enqueue(conn, account["id"], "my-iphone", "health.query",
                               {"metric": "hrv", "interval": "hour"})

    body = client.get("/bridge/jobs", headers=auth(account),
                      params={"device": "my-iphone"}).json()
    assert body["poll_after_seconds"] == 30
    assert [job["id"] for job in body["jobs"]] == [info_id, hrv_id]
    info, hrv = body["jobs"]
    assert set(info) == {"id", "capability", "created_at"}       # no params key when there are none
    assert info["capability"] == "device.info"
    assert hrv["params"] == {"metric": "hrv", "interval": "hour"}

    # Leased: the same poll again gets nothing.
    assert client.get("/bridge/jobs", headers=auth(account),
                      params={"device": "my-iphone"}).json()["jobs"] == []
    assert store.get_job(conn, info_id)["status"] == "leased"


def test_an_expired_lease_is_offered_again(client, conn, account):
    with conn:
        job_id = store.enqueue(conn, account["id"], "my-iphone", "device.info")
    client.get("/bridge/jobs", headers=auth(account), params={"device": "my-iphone"})
    with conn:
        conn.execute("UPDATE jobs SET lease_until = ? WHERE id = ?", (time.time() - 1, job_id))
    body = client.get("/bridge/jobs", headers=auth(account), params={"device": "my-iphone"}).json()
    assert [job["id"] for job in body["jobs"]] == [job_id]


def test_results_complete_a_job_and_ignore_duplicates(client, conn, account):
    with conn:
        job_id = store.enqueue(conn, account["id"], "my-iphone", "device.info")
    client.get("/bridge/jobs", headers=auth(account), params={"device": "my-iphone"})
    payload = {"device": "my-iphone", "results": [{
        "job_id": job_id, "ok": True, "result": {"battery_level": 0.82},
        "started_at": "2026-10-16T00:00:01Z", "finished_at": "2026-10-16T00:00:02Z"}]}

    first = client.post("/bridge/results", headers=auth(account), json=payload).json()
    assert first == {"ok": True, "accepted": 1, "duplicate": 0, "unknown": 0, "invalid": 0}
    second = client.post("/bridge/results", headers=auth(account), json=payload).json()
    assert second["accepted"] == 0 and second["duplicate"] == 1

    job = store.job_dict(store.get_job(conn, job_id))
    assert job["status"] == "done"
    assert job["result"]["result"]["battery_level"] == 0.82
    assert job["result"]["finished_at"] == "2026-10-16T00:00:02Z"


def test_results_for_an_unknown_job_are_counted_not_fatal(client, account):
    body = client.post("/bridge/results", headers=auth(account), json={
        "device": "my-iphone", "results": [{"job_id": "j_nope", "ok": True}, "junk"]}).json()
    assert body == {"ok": True, "accepted": 0, "duplicate": 0, "unknown": 1, "invalid": 1}


def test_results_must_be_a_list(client, account):
    response = client.post("/bridge/results", headers=auth(account),
                           json={"device": "my-iphone", "results": {}})
    assert response.status_code == 400


def test_a_malformed_body_is_a_400(client, account):
    response = client.post("/bridge/results", headers=auth(account), content=b"not json")
    assert response.status_code == 400 and response.json()["error"] == "body must be JSON"


def test_one_tenant_cannot_see_or_finish_another_tenants_job(client, conn, account,
                                                             other_account):
    """Both tenants call their phone "my-iphone"; nothing may cross."""
    with conn:
        mine = store.enqueue(conn, account["id"], "my-iphone", "device.info")
        theirs = store.enqueue(conn, other_account["id"], "my-iphone", "location.now")

    mine_jobs = client.get("/bridge/jobs", headers=auth(account),
                           params={"device": "my-iphone"}).json()["jobs"]
    assert [job["id"] for job in mine_jobs] == [mine]

    stolen = client.post("/bridge/results", headers=auth(account), json={
        "device": "my-iphone", "results": [{"job_id": theirs, "ok": True, "result": {}}]}).json()
    assert stolen["unknown"] == 1
    assert store.get_job(conn, theirs)["status"] == "queued"


def test_a_job_for_another_device_of_the_same_account_is_not_handed_over(client, conn, account):
    with conn:
        store.enqueue(conn, account["id"], "ipad", "device.info")
    assert client.get("/bridge/jobs", headers=auth(account),
                      params={"device": "my-iphone"}).json()["jobs"] == []


def test_every_call_leaves_an_audit_row_and_no_bodies(client, conn, account):
    with conn:
        job_id = store.enqueue(conn, account["id"], "my-iphone", "device.info")
    client.get("/bridge/ping", headers=auth(account), params={"device": "my-iphone"})
    client.post("/bridge/devices", headers=auth(account),
                json={"device": "my-iphone", "apns_token": "a" * 64})
    client.get("/bridge/jobs", headers=auth(account), params={"device": "my-iphone"})
    client.post("/bridge/results", headers=auth(account), json={
        "device": "my-iphone",
        "results": [{"job_id": job_id, "ok": True, "result": {"lat": 37.3349, "lon": -122.009}}]})
    client.get("/bridge/ping", headers={"Authorization": "Bearer brg_wrong",
                                        "X-Bridge-Device": "my-iphone"})

    rows = store.audit_tail(conn, limit=20)
    seen = [(row["endpoint"], row["outcome"]) for row in rows]
    assert ("GET /bridge/ping", "ok") in seen
    assert ("POST /bridge/devices", "registered") in seen
    assert ("GET /bridge/jobs", "leased:1") in seen
    assert ("POST /bridge/results", "accepted:1 dup:0 unknown:0") in seen
    assert ("GET /bridge/ping", "unauthorized") in seen

    unauthorized = [row for row in rows if row["outcome"] == "unauthorized"][0]
    assert unauthorized["account_id"] is None          # no account to pin it on
    assert unauthorized["device_id"] == "my-iphone"    # but the claimed device is kept

    blob = " ".join(str(tuple(row)) for row in rows)
    for secret in ("37.3349", "-122.009", "battery", account["token"], "a" * 64):
        assert secret not in blob
