"""SQLite storage for the Bridge server.

Design notes (the "why", so a later reader does not undo them):

* MULTI-TENANT FROM DAY ONE. Every row carries ``account_id`` and every query is scoped by it.
  A device id is unique only *within* an account, so two tenants may both call their phone
  "my-iphone". Tokens are per account, stored as a sha256 hex digest, compared constant-time.
* AUDIT-READY. ``audit`` is append-only (a trigger blocks UPDATE) and records only
  ts / account / device / endpoint / outcome — never a request or result body. The single
  deletion path is ``purge_device``, which is the erasure tool, not a maintenance shortcut.
* Results can hold health and location data, so the database file (and its WAL sidecars)
  are created 0600 and the directory 0700.
* Shape borrowed from Hermes-iOS' connector schema: an append-only history (``jobs``,
  ``audit``) beside a one-row-per-device "latest" cache (``devices``), the way it keeps
  ``health_samples`` beside ``health_latest``; and a composite index on the hot lookup.
"""
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import config

TOKEN_PREFIX = "brg_"
CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
    id         TEXT PRIMARY KEY,
    label      TEXT NOT NULL UNIQUE,
    token_hash TEXT NOT NULL UNIQUE,
    created    TEXT NOT NULL,
    revoked_at TEXT
);

CREATE TABLE IF NOT EXISTS devices (
    account_id TEXT NOT NULL REFERENCES accounts(id),
    device_id  TEXT NOT NULL,
    apns_token TEXT,
    last_seen  TEXT,
    meta       TEXT,            -- JSON: app_version, capabilities, apns_environment
    created    TEXT NOT NULL,
    PRIMARY KEY (account_id, device_id)
);

CREATE TABLE IF NOT EXISTS jobs (
    id          TEXT PRIMARY KEY,
    account_id  TEXT NOT NULL,
    device_id   TEXT NOT NULL,
    capability  TEXT NOT NULL,
    params_json TEXT,
    status      TEXT NOT NULL CHECK (status IN ('queued','leased','done','failed')),
    lease_until REAL,            -- epoch seconds; NULL unless leased
    attempts    INTEGER NOT NULL DEFAULT 0,
    result_json TEXT,            -- the whole result envelope from the phone
    created     TEXT NOT NULL,
    updated     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS jobs_queue ON jobs(account_id, device_id, status);
CREATE INDEX IF NOT EXISTS jobs_lease ON jobs(status, lease_until);

CREATE TABLE IF NOT EXISTS audit (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         TEXT NOT NULL,
    account_id TEXT,
    device_id  TEXT,
    endpoint   TEXT NOT NULL,
    outcome    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS audit_scope ON audit(account_id, device_id, ts);

-- Append-only: rows may be written and (only by purge_device) erased, never rewritten.
CREATE TRIGGER IF NOT EXISTS audit_no_update BEFORE UPDATE ON audit
BEGIN SELECT RAISE(ABORT, 'audit is append-only'); END;
"""


# ---------------------------------------------------------------- small helpers

def now_iso():
    """UTC, seconds resolution, ISO-8601 with a Z — what the phone's ISO parser expects."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


_id_lock = threading.Lock()
_last_id = (0, 0)


def new_id(prefix=""):
    """ULID: 48-bit ms timestamp + 80 random bits in Crockford base32, so ids sort by age.

    Monotonic within a process: ids minted in the same millisecond increment instead of being
    re-randomised, so a burst of enqueues keeps its order (ULID's monotonic rule). Two
    processes writing in the same millisecond can still interleave — order is by time, not a
    sequence number.
    """
    global _last_id
    with _id_lock:
        millis = int(time.time() * 1000)
        last_millis, last_rand = _last_id
        rand = last_rand + 1 if millis == last_millis else secrets.randbits(80)
        _last_id = (millis, rand)
    value = (millis << 80) | (rand & ((1 << 80) - 1))
    out = "".join(CROCKFORD[(value >> shift) & 31] for shift in range(125, -1, -5))
    return prefix + out


def hash_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def new_token():
    return TOKEN_PREFIX + secrets.token_urlsafe(32)


def _json(value):
    return None if value is None else json.dumps(value, separators=(",", ":"))


def unjson(text):
    return None if text in (None, "") else json.loads(text)


# ---------------------------------------------------------------- connection

def connect(path=None):
    path = Path(path) if path else config.db_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fresh = not path.exists()
    conn = sqlite3.connect(str(path), timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(SCHEMA)
    if fresh:
        os.chmod(path, 0o600)
    _tighten(path)
    return conn


def _tighten(path):
    """Health and location data: keep the DB and its WAL sidecars owner-only."""
    for p in (path, Path(str(path) + "-wal"), Path(str(path) + "-shm")):
        try:
            if p.exists() and (p.stat().st_mode & 0o077):
                os.chmod(p, 0o600)
        except OSError:
            pass


# ---------------------------------------------------------------- accounts

def create_account(conn, label):
    """Returns (account_id, token). The token is shown once and never stored in the clear."""
    token = new_token()
    account_id = new_id("a_")
    conn.execute(
        "INSERT INTO accounts (id, label, token_hash, created) VALUES (?,?,?,?)",
        (account_id, label, hash_token(token), now_iso()),
    )
    return account_id, token


def find_account(conn, ref):
    """Look an account up by label or by id."""
    return conn.execute(
        "SELECT * FROM accounts WHERE label = ? OR id = ?", (ref, ref)
    ).fetchone()


def list_accounts(conn):
    return conn.execute("SELECT * FROM accounts ORDER BY created").fetchall()


def revoke_account(conn, ref):
    row = find_account(conn, ref)
    if row is None or row["revoked_at"]:
        return row
    conn.execute("UPDATE accounts SET revoked_at = ? WHERE id = ?", (now_iso(), row["id"]))
    return find_account(conn, ref)


def account_for_token(conn, token):
    """Constant-time token check against every live account. Revoked accounts never match."""
    if not token:
        return None
    candidate = hash_token(token)
    found = None
    for row in conn.execute("SELECT * FROM accounts WHERE revoked_at IS NULL"):
        if hmac.compare_digest(candidate, row["token_hash"]):
            found = row
    return found


# ---------------------------------------------------------------- devices

def touch_device(conn, account_id, device_id, apns_token=None, meta_updates=None):
    """Upsert the per-device "latest" row: last_seen always, token/meta when supplied."""
    row = conn.execute(
        "SELECT * FROM devices WHERE account_id = ? AND device_id = ?", (account_id, device_id)
    ).fetchone()
    ts = now_iso()
    if row is None:
        conn.execute(
            "INSERT INTO devices (account_id, device_id, apns_token, last_seen, meta, created)"
            " VALUES (?,?,?,?,?,?)",
            (account_id, device_id, apns_token, ts, _json(meta_updates or {}), ts),
        )
        return
    meta = unjson(row["meta"]) or {}
    if meta_updates:
        meta.update({k: v for k, v in meta_updates.items() if v is not None})
    conn.execute(
        "UPDATE devices SET last_seen = ?, apns_token = COALESCE(?, apns_token), meta = ?"
        " WHERE account_id = ? AND device_id = ?",
        (ts, apns_token, _json(meta), account_id, device_id),
    )


def get_device(conn, account_id, device_id):
    return conn.execute(
        "SELECT * FROM devices WHERE account_id = ? AND device_id = ?", (account_id, device_id)
    ).fetchone()


def list_devices(conn, account_id=None):
    if account_id:
        return conn.execute(
            "SELECT * FROM devices WHERE account_id = ? ORDER BY device_id", (account_id,)
        ).fetchall()
    return conn.execute("SELECT * FROM devices ORDER BY account_id, device_id").fetchall()


def purge_device(conn, account_id, device_id):
    """Erase every trace of one device. Returns the row counts deleted, per table."""
    counts = {}
    with conn:
        for table in ("jobs", "audit", "devices"):
            cur = conn.execute(
                f"DELETE FROM {table} WHERE account_id = ? AND device_id = ?",
                (account_id, device_id),
            )
            counts[table] = cur.rowcount
    counts["results"] = counts["jobs"]  # results live on the job row; counted for the report
    return counts


# ---------------------------------------------------------------- jobs

def enqueue(conn, account_id, device_id, capability, params=None):
    job_id = new_id("j_")
    ts = now_iso()
    conn.execute(
        "INSERT INTO jobs (id, account_id, device_id, capability, params_json, status,"
        " attempts, created, updated) VALUES (?,?,?,?,?,'queued',0,?,?)",
        (job_id, account_id, device_id, capability, _json(params), ts, ts),
    )
    return job_id


def reclaim_expired(conn, max_attempts=None):
    """A lease that ran out goes back to the queue; after max_attempts tries the job fails.

    This is the at-least-once half of the contract in docs/API.md: the phone may die between
    being handed a job and posting its result, and nothing else would ever notice.
    """
    max_attempts = max_attempts or config.get_int("BRIDGE_MAX_ATTEMPTS")
    ts, clock = now_iso(), time.time()
    expired = conn.execute(
        "SELECT id, attempts FROM jobs WHERE status = 'leased' AND lease_until IS NOT NULL"
        " AND lease_until < ?", (clock,),
    ).fetchall()
    requeued = failed = 0
    for row in expired:
        if row["attempts"] >= max_attempts:
            conn.execute(
                "UPDATE jobs SET status='failed', lease_until=NULL, result_json=?, updated=?"
                " WHERE id = ?",
                (_json({
                    "job_id": row["id"], "ok": False,
                    "error": {"code": "timeout",
                              "message": f"no result after {max_attempts} lease attempts"},
                }), ts, row["id"]),
            )
            failed += 1
        else:
            conn.execute(
                "UPDATE jobs SET status='queued', lease_until=NULL, updated=? WHERE id = ?",
                (ts, row["id"]),
            )
            requeued += 1
    return requeued, failed


def lease_jobs(conn, account_id, device_id, limit=None, lease_seconds=None):
    """Hand queued jobs to one device and lease them. Scoped to the caller's account."""
    limit = limit or config.get_int("BRIDGE_MAX_JOBS_PER_POLL")
    lease_seconds = lease_seconds or config.get_int("BRIDGE_LEASE_SECONDS")
    ts, until = now_iso(), time.time() + lease_seconds
    with conn:
        reclaim_expired(conn)
        rows = conn.execute(
            "SELECT * FROM jobs WHERE account_id = ? AND device_id = ? AND status = 'queued'"
            " ORDER BY created, id LIMIT ?", (account_id, device_id, limit),
        ).fetchall()
        for row in rows:
            conn.execute(
                "UPDATE jobs SET status='leased', lease_until=?, attempts=attempts+1, updated=?"
                " WHERE id = ? AND status = 'queued'", (until, ts, row["id"]),
            )
    return rows


def record_result(conn, account_id, device_id, result):
    """Store one result. Duplicates for an already-finished job are ignored, by contract."""
    job_id = result.get("job_id")
    if not job_id:
        return "invalid"
    row = conn.execute(
        "SELECT * FROM jobs WHERE id = ? AND account_id = ? AND device_id = ?",
        (job_id, account_id, device_id),
    ).fetchone()
    if row is None:
        return "unknown"
    if row["status"] in ("done", "failed"):
        return "duplicate"
    conn.execute(
        "UPDATE jobs SET status = ?, lease_until = NULL, result_json = ?, updated = ?"
        " WHERE id = ?",
        ("done" if result.get("ok") else "failed", _json(result), now_iso(), job_id),
    )
    return "accepted"


def get_job(conn, job_id, account_id=None):
    if account_id:
        return conn.execute(
            "SELECT * FROM jobs WHERE id = ? AND account_id = ?", (job_id, account_id)
        ).fetchone()
    return conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()


def job_dict(row):
    """Row -> the JSON shape the CLI prints (params/result decoded, lease as a plain number)."""
    if row is None:
        return None
    return {
        "id": row["id"], "account_id": row["account_id"], "device_id": row["device_id"],
        "capability": row["capability"], "params": unjson(row["params_json"]),
        "status": row["status"], "attempts": row["attempts"],
        "lease_until": row["lease_until"], "result": unjson(row["result_json"]),
        "created": row["created"], "updated": row["updated"],
    }


# ---------------------------------------------------------------- audit

def audit(conn, account_id, device_id, endpoint, outcome):
    """Append one audit row. Never called with a body, a token or a result — by design."""
    conn.execute(
        "INSERT INTO audit (ts, account_id, device_id, endpoint, outcome) VALUES (?,?,?,?,?)",
        (now_iso(), account_id, device_id, endpoint, outcome),
    )


def audit_tail(conn, account_id=None, device_id=None, limit=50):
    sql = "SELECT * FROM audit"
    where, args = [], []
    if account_id:
        where.append("account_id = ?")
        args.append(account_id)
    if device_id:
        where.append("device_id = ?")
        args.append(device_id)
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY id DESC LIMIT ?"
    args.append(limit)
    return conn.execute(sql, args).fetchall()
