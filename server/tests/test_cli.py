"""The operator CLI. Same database as the server, so these run against the API's state too."""
import json

import pytest

import cli
import db as store


def run(capsys, *argv):
    cli.main(list(argv))
    captured = capsys.readouterr()
    return captured.out, captured.err


def test_account_create_prints_the_token_once_then_never_again(db_path, capsys):
    out, _ = run(capsys, "account", "create", "mu")
    token = out.strip().splitlines()[-1]
    assert token.startswith("brg_")
    listing, _ = run(capsys, "account", "list")
    assert "mu" in listing and token not in listing


def test_account_create_can_write_the_token_to_a_600_file_instead(db_path, tmp_path, capsys):
    target = tmp_path / "mu.token"
    out, _ = run(capsys, "account", "create", "mu", "--token-file", str(target))
    assert target.read_text().strip().startswith("brg_")
    assert oct(target.stat().st_mode & 0o777) == "0o600"
    assert target.read_text().strip() not in out      # the pane never sees it


def test_revoke_then_the_token_is_dead(db_path, conn, capsys):
    run(capsys, "account", "create", "throwaway")
    row = store.find_account(conn, "throwaway")
    assert row["revoked_at"] is None
    run(capsys, "account", "revoke", "throwaway")
    assert store.find_account(conn, "throwaway")["revoked_at"] is not None


def test_unknown_account_is_an_error_not_a_traceback(db_path, capsys):
    with pytest.raises(SystemExit) as exit_info:
        run(capsys, "job", "enqueue", "ghost", "d1", "device.info")
    assert exit_info.value.code == 2


def test_enqueue_get_and_wait_round_trip(db_path, conn, account, capsys):
    out, err = run(capsys, "job", "enqueue", "tenant-a", "my-iphone",
                   "health.query", '{"metric":"hrv"}')
    job_id = out.strip()
    assert job_id.startswith("j_")
    assert "never registered" in err         # no device row yet, so no push was attempted

    shown, _ = run(capsys, "job", "get", job_id)
    job = json.loads(shown)
    assert job["status"] == "queued" and job["params"] == {"metric": "hrv"}

    with pytest.raises(SystemExit) as exit_info:      # nothing answers; wait times out
        run(capsys, "job", "wait", job_id, "--timeout", "0.2", "--interval", "0.05")
    assert exit_info.value.code == 3

    store.lease_jobs(conn, account["id"], "my-iphone")
    with conn:
        store.record_result(conn, account["id"], "my-iphone",
                            {"job_id": job_id, "ok": True, "result": {"count": 3}})
    with pytest.raises(SystemExit) as exit_info:
        run(capsys, "job", "wait", job_id, "--timeout", "2")
    assert exit_info.value.code == 0


def test_wait_exits_nonzero_when_the_phone_reports_a_failure(db_path, conn, account, capsys):
    with conn:
        job_id = store.enqueue(conn, account["id"], "my-iphone", "location.now")
    store.lease_jobs(conn, account["id"], "my-iphone")
    with conn:
        store.record_result(conn, account["id"], "my-iphone", {
            "job_id": job_id, "ok": False,
            "error": {"code": "permission_denied", "message": "Location is off"}})
    with pytest.raises(SystemExit) as exit_info:
        run(capsys, "job", "wait", job_id, "--timeout", "2")
    assert exit_info.value.code == 1


def test_device_list_and_purge_report_what_they_touched(db_path, conn, account, capsys):
    with conn:
        store.touch_device(conn, account["id"], "my-iphone", apns_token="a" * 64,
                           meta_updates={"app_version": "0.1.0 (1)",
                                         "capabilities": ["device.info"]})
        store.enqueue(conn, account["id"], "my-iphone", "device.info")
        store.audit(conn, account["id"], "my-iphone", "GET /bridge/ping", "ok")

    listing, _ = run(capsys, "device", "list", "--account", "tenant-a")
    assert "my-iphone" in listing and "device.info" in listing and "a" * 64 not in listing

    out, _ = run(capsys, "device", "purge", "tenant-a", "my-iphone")
    assert "jobs 1" in out and "audit 1" in out and "device rows 1" in out
    assert store.get_device(conn, account["id"], "my-iphone") is None


def test_push_without_apns_configured_is_a_clean_no_op(db_path, conn, account, capsys):
    with conn:
        store.touch_device(conn, account["id"], "my-iphone", apns_token="a" * 64)
    with pytest.raises(SystemExit) as exit_info:
        run(capsys, "push", "tenant-a", "my-iphone")
    assert exit_info.value.code == 1          # nothing was sent …
    assert store.audit_tail(conn, account["id"])[0]["outcome"] == "push:unconfigured"  # … and we said so
