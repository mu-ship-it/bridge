#!/usr/bin/env python3
"""``bridge`` — operator CLI for the Bridge box.

    bridge account create <label> [--token-file PATH]
    bridge account list
    bridge account revoke <label|id>
    bridge devices [--account <label|id>]          (same as `device list`)
    bridge device list [--account <label|id>]
    bridge device purge <account> <device>
    bridge job enqueue <account> <device> <capability> [params-json] [--no-push]
    bridge job get <id>
    bridge job wait <id> [--timeout 120]
    bridge push <account> <device> [--kind poll|sync]
    bridge events <account> [--device D] [--type T] [--since ID|ISO] [--limit 100] [--json]
    bridge audit tail [--account X] [--device Y] [--limit 50]

Runs against the same database as the server (BRIDGE_DB), so it works whether or not the
service is up.
"""
import argparse
import json
import sys
import time
from contextlib import closing

import apns
import db


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def resolve_account(conn, ref):
    account = db.find_account(conn, ref)
    if account is None:
        fail(f"no such account: {ref}")
    return account


def resolve_device(conn, account, device_id):
    device = db.get_device(conn, account["id"], device_id)
    if device is None:
        fail(f"no such device for account {account['label']}: {device_id}")
    return device


# ---------------------------------------------------------------- accounts

def cmd_account_create(conn, args):
    with conn:
        account_id, token = db.create_account(conn, args.label)
    if args.token_file:
        path = args.token_file
        with open(path, "w") as fh:
            fh.write(token + "\n")
        import os
        os.chmod(path, 0o600)
        print(f"account {args.label} ({account_id}) created; token written to {path} (mode 600)")
    else:
        print(f"account {args.label} ({account_id}) created")
        print("token (shown once, store it now):")
        print(token)


def cmd_account_list(conn, args):
    rows = db.list_accounts(conn)
    if not rows:
        print("no accounts")
    for row in rows:
        state = f"revoked {row['revoked_at']}" if row["revoked_at"] else "active"
        print(f"{row['label']:<20} {row['id']}  created {row['created']}  {state}")


def cmd_account_revoke(conn, args):
    with conn:
        row = db.revoke_account(conn, args.ref)
    if row is None:
        fail(f"no such account: {args.ref}")
    print(f"account {row['label']} ({row['id']}) revoked at {row['revoked_at']}")


# ---------------------------------------------------------------- devices

def cmd_device_list(conn, args):
    account_id = resolve_account(conn, args.account)["id"] if args.account else None
    rows = db.list_devices(conn, account_id)
    if not rows:
        print("no devices")
    for row in rows:
        d = db.device_dict(row)
        caps = ",".join(d["capabilities"]) or "-"
        print(f"{d['account_id']}  {d['device_id']:<16} last_seen {d['last_seen']}  "
              f"duty {duty_text(d)}  apns {'yes' if d['apns'] else 'no'}  "
              f"app {d['app_version'] or '-'}  caps {caps}")


def duty_text(device):
    if device["duty_stale"]:
        return f"stale(last beat {device['heartbeat_at']})"
    if device["duty"]:
        return f"on(beat {device['heartbeat_at']})"
    return "off"


def cmd_device_purge(conn, args):
    account = resolve_account(conn, args.account)
    counts = db.purge_device(conn, account["id"], args.device)
    print(f"purged device {args.device} of account {account['label']}: "
          f"jobs {counts['jobs']} (results {counts['results']}), "
          f"events {counts['events']}, suggest taps {counts['suggest_taps']}, audit {counts['audit']}, "
          f"device rows {counts['devices']}")


# ---------------------------------------------------------------- jobs

def cmd_job_enqueue(conn, args):
    account = resolve_account(conn, args.account)
    params = None
    if args.params:
        try:
            params = json.loads(args.params)
        except json.JSONDecodeError as exc:
            fail(f"params must be JSON: {exc}")
    with conn:
        job_id = db.enqueue(conn, account["id"], args.device, args.capability, params)
    print(job_id)
    if args.no_push:
        return
    device = db.get_device(conn, account["id"], args.device)
    if device is None:
        print("note: device has never registered; it will get the job on its next poll",
              file=sys.stderr)
        return
    meta = db.unjson(device["meta"]) or {}
    outcome = apns.push(device["apns_token"], meta.get("apns_environment"))
    with conn:
        db.audit(conn, account["id"], args.device, "cli job enqueue", outcome.outcome)
    if not outcome.sent:
        print(f"note: no push ({outcome.detail}); the phone will pick the job up when it polls",
              file=sys.stderr)


def cmd_job_get(conn, args):
    with conn:
        db.reclaim_expired(conn)
    job = db.job_dict(db.get_job(conn, args.id))
    if job is None:
        fail(f"no such job: {args.id}")
    print(json.dumps(job, indent=2, ensure_ascii=False))


def cmd_job_wait(conn, args):
    deadline = time.time() + args.timeout
    while True:
        with conn:
            db.reclaim_expired(conn)
        job = db.job_dict(db.get_job(conn, args.id))
        if job is None:
            fail(f"no such job: {args.id}")
        if job["status"] in ("done", "failed"):
            print(json.dumps(job, indent=2, ensure_ascii=False))
            raise SystemExit(0 if job["status"] == "done" else 1)
        if time.time() >= deadline:
            print(f"timeout after {args.timeout}s; job is {job['status']} "
                  f"(attempt {job['attempts']})", file=sys.stderr)
            raise SystemExit(3)
        time.sleep(args.interval)


def cmd_push(conn, args):
    account = resolve_account(conn, args.account)
    device = resolve_device(conn, account, args.device)
    meta = db.unjson(device["meta"]) or {}
    outcome = apns.push(device["apns_token"], meta.get("apns_environment"), kind=args.kind)
    with conn:
        db.audit(conn, account["id"], args.device, "cli push", outcome.outcome)
    print(f"push {args.kind} -> {args.device}: {outcome.detail}"
          + (f" ({outcome.status})" if outcome.status else ""))
    raise SystemExit(0 if outcome.sent else 1)


def cmd_events(conn, args):
    account = resolve_account(conn, args.account)
    since = args.since
    if since and not since.startswith("e_"):
        try:
            since = db.normalize_iso(since)
        except ValueError:
            fail("--since must be an event id or an ISO-8601 time with a timezone")
    rows = db.list_events(conn, account["id"], args.device, since, args.type, args.limit)
    events = [db.event_dict(row) for row in rows]
    if args.json:
        print(json.dumps(events, indent=2, ensure_ascii=False))
        return
    if not events:
        print("no events")
    for e in events:
        payload = json.dumps(e["payload"], ensure_ascii=False) if e["payload"] else ""
        if len(payload) > 120:
            payload = payload[:117] + "..."
        print(f"{e['id']}  {e['ts']}  {e['device']:<16} {e['type']:<10} {e['note']}  {payload}")


def cmd_audit_tail(conn, args):
    account_id = resolve_account(conn, args.account)["id"] if args.account else None
    rows = db.audit_tail(conn, account_id, args.device, args.limit)
    for row in reversed(rows):
        print(f"{row['ts']}  {row['account_id'] or '-':<28} {row['device_id'] or '-':<16} "
              f"{row['endpoint']:<22} {row['outcome']}")


# ---------------------------------------------------------------- wiring

def build_parser():
    parser = argparse.ArgumentParser(prog="bridge", description="Bridge box operator CLI")
    sub = parser.add_subparsers(dest="group", required=True)

    account = sub.add_parser("account").add_subparsers(dest="action", required=True)
    create = account.add_parser("create")
    create.add_argument("label")
    create.add_argument("--token-file", help="write the token to this file (600) instead of stdout")
    create.set_defaults(func=cmd_account_create)
    account.add_parser("list").set_defaults(func=cmd_account_list)
    revoke = account.add_parser("revoke")
    revoke.add_argument("ref", help="label or id")
    revoke.set_defaults(func=cmd_account_revoke)

    devices = sub.add_parser("devices", help="list devices (same as `device list`)")
    devices.add_argument("--account")
    devices.set_defaults(func=cmd_device_list)

    events = sub.add_parser("events", help="device-originated events, oldest first")
    events.add_argument("account")
    events.add_argument("--device")
    events.add_argument("--type")
    events.add_argument("--since", help="event id (exclusive) or ISO-8601 time")
    events.add_argument("--limit", type=int, default=100)
    events.add_argument("--json", action="store_true")
    events.set_defaults(func=cmd_events)

    device = sub.add_parser("device").add_subparsers(dest="action", required=True)
    listing = device.add_parser("list")
    listing.add_argument("--account")
    listing.set_defaults(func=cmd_device_list)
    purge = device.add_parser("purge")
    purge.add_argument("account")
    purge.add_argument("device")
    purge.set_defaults(func=cmd_device_purge)

    job = sub.add_parser("job").add_subparsers(dest="action", required=True)
    enqueue = job.add_parser("enqueue")
    enqueue.add_argument("account")
    enqueue.add_argument("device")
    enqueue.add_argument("capability")
    enqueue.add_argument("params", nargs="?", help="JSON object")
    enqueue.add_argument("--no-push", action="store_true")
    enqueue.set_defaults(func=cmd_job_enqueue)
    get = job.add_parser("get")
    get.add_argument("id")
    get.set_defaults(func=cmd_job_get)
    wait = job.add_parser("wait")
    wait.add_argument("id")
    wait.add_argument("--timeout", type=float, default=120)
    wait.add_argument("--interval", type=float, default=1.0)
    wait.set_defaults(func=cmd_job_wait)

    push = sub.add_parser("push")
    push.add_argument("account")
    push.add_argument("device")
    push.add_argument("--kind", choices=["poll", "sync"], default="poll")
    push.set_defaults(func=cmd_push)

    audit = sub.add_parser("audit").add_subparsers(dest="action", required=True)
    tail = audit.add_parser("tail")
    tail.add_argument("--account")
    tail.add_argument("--device")
    tail.add_argument("--limit", type=int, default=50)
    tail.set_defaults(func=cmd_audit_tail)

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    with closing(db.connect()) as conn:
        args.func(conn, args)


if __name__ == "__main__":
    main()
