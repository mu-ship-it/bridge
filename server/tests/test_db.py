"""Storage-level behaviour: tenancy, tokens, leases, erasure, audit immutability."""
import json
import sqlite3
import time

import pytest

import db as store


def test_token_is_never_stored_in_the_clear(conn, account):
    row = store.find_account(conn, "tenant-a")
    assert row["token_hash"] != account["token"]
    assert row["token_hash"] == store.hash_token(account["token"])
    dump = "".join(line for line in conn.iterdump())
    assert account["token"] not in dump


def test_only_the_right_live_token_authenticates(conn, account, other_account):
    assert store.account_for_token(conn, account["token"])["id"] == account["id"]
    assert store.account_for_token(conn, other_account["token"])["id"] == other_account["id"]
    assert store.account_for_token(conn, "brg_nope") is None
    assert store.account_for_token(conn, "") is None
    with conn:
        store.revoke_account(conn, "tenant-a")
    assert store.account_for_token(conn, account["token"]) is None


def test_device_id_is_unique_only_within_an_account(conn, account, other_account):
    with conn:
        store.touch_device(conn, account["id"], "my-iphone", apns_token="a" * 64)
        store.touch_device(conn, other_account["id"], "my-iphone", apns_token="b" * 64)
    assert store.get_device(conn, account["id"], "my-iphone")["apns_token"] == "a" * 64
    assert store.get_device(conn, other_account["id"], "my-iphone")["apns_token"] == "b" * 64
    assert len(store.list_devices(conn, account["id"])) == 1


def test_touch_device_keeps_the_apns_token_when_a_later_call_omits_it(conn, account):
    with conn:
        store.touch_device(conn, account["id"], "d1", apns_token="a" * 64,
                           meta_updates={"app_version": "0.1.0 (1)"})
        first_seen = store.get_device(conn, account["id"], "d1")["last_seen"]
        store.touch_device(conn, account["id"], "d1")
    row = store.get_device(conn, account["id"], "d1")
    assert row["apns_token"] == "a" * 64
    assert json.loads(row["meta"])["app_version"] == "0.1.0 (1)"
    assert row["last_seen"] >= first_seen


def test_lease_hides_a_job_until_the_lease_runs_out(conn, account):
    with conn:
        job_id = store.enqueue(conn, account["id"], "d1", "device.info")
    assert [r["id"] for r in store.lease_jobs(conn, account["id"], "d1")] == [job_id]
    assert store.lease_jobs(conn, account["id"], "d1") == []
    with conn:  # make the lease look expired
        conn.execute("UPDATE jobs SET lease_until = ? WHERE id = ?", (time.time() - 1, job_id))
    assert [r["id"] for r in store.lease_jobs(conn, account["id"], "d1")] == [job_id]
    assert store.get_job(conn, job_id)["attempts"] == 2


def test_a_job_fails_after_three_lease_attempts(conn, account):
    with conn:
        job_id = store.enqueue(conn, account["id"], "d1", "device.info")
    for _ in range(3):
        store.lease_jobs(conn, account["id"], "d1")
        with conn:
            conn.execute("UPDATE jobs SET lease_until = ? WHERE id = ?", (time.time() - 1, job_id))
    with conn:
        requeued, failed = store.reclaim_expired(conn)
    assert (requeued, failed) == (0, 1)
    job = store.job_dict(store.get_job(conn, job_id))
    assert job["status"] == "failed"
    assert job["result"]["error"]["code"] == "timeout"
    assert store.lease_jobs(conn, account["id"], "d1") == []


def test_results_are_recorded_once_and_scoped_to_the_account(conn, account, other_account):
    with conn:
        job_id = store.enqueue(conn, account["id"], "d1", "device.info")
    store.lease_jobs(conn, account["id"], "d1")
    result = {"job_id": job_id, "ok": True, "result": {"battery_level": 0.8}}
    with conn:
        assert store.record_result(conn, other_account["id"], "d1", result) == "unknown"
        assert store.record_result(conn, account["id"], "d1", result) == "accepted"
        assert store.record_result(conn, account["id"], "d1", result) == "duplicate"
        assert store.record_result(conn, account["id"], "d1", {"ok": True}) == "invalid"
    job = store.job_dict(store.get_job(conn, job_id))
    assert job["status"] == "done" and job["result"]["result"]["battery_level"] == 0.8


def test_a_failed_result_is_terminal_and_keeps_the_error(conn, account):
    with conn:
        job_id = store.enqueue(conn, account["id"], "d1", "location.now", {"timeout": 15})
    store.lease_jobs(conn, account["id"], "d1")
    with conn:
        store.record_result(conn, account["id"], "d1", {
            "job_id": job_id, "ok": False,
            "error": {"code": "permission_missing", "message": "Location not requested yet"}})
    job = store.job_dict(store.get_job(conn, job_id))
    assert job["status"] == "failed"
    assert job["result"]["error"]["code"] == "permission_missing"
    assert job["params"] == {"timeout": 15}


def test_purge_removes_every_row_for_one_device_and_nothing_else(conn, account, other_account):
    with conn:
        for owner in (account, other_account):
            store.touch_device(conn, owner["id"], "my-iphone")
            store.enqueue(conn, owner["id"], "my-iphone", "device.info")
            store.audit(conn, owner["id"], "my-iphone", "GET /bridge/ping", "ok")
        store.touch_device(conn, account["id"], "keep-me")
        store.enqueue(conn, account["id"], "keep-me", "device.info")

    counts = store.purge_device(conn, account["id"], "my-iphone")
    assert counts == {"jobs": 1, "audit": 1, "devices": 1, "results": 1}
    assert store.get_device(conn, account["id"], "my-iphone") is None
    assert store.get_device(conn, account["id"], "keep-me") is not None
    assert store.get_device(conn, other_account["id"], "my-iphone") is not None
    assert len(store.audit_tail(conn, other_account["id"], "my-iphone")) == 1
    assert conn.execute("SELECT COUNT(*) FROM jobs WHERE account_id = ?",
                        (account["id"],)).fetchone()[0] == 1


def test_audit_rows_cannot_be_rewritten(conn, account):
    with conn:
        store.audit(conn, account["id"], "d1", "GET /bridge/ping", "ok")
    with pytest.raises(sqlite3.IntegrityError, match="append-only"):
        conn.execute("UPDATE audit SET outcome = 'tampered'")
    assert store.audit_tail(conn, account["id"])[0]["outcome"] == "ok"


def test_database_file_is_owner_only(conn, db_path):
    assert oct(db_path.stat().st_mode & 0o777) == "0o600"


def test_job_ids_sort_by_age(conn, account):
    """Ids are time-ordered, and monotonic within a process even inside one millisecond."""
    with conn:
        ids = [store.enqueue(conn, account["id"], "d1", "device.info") for _ in range(5)]
    assert ids == sorted(ids)
