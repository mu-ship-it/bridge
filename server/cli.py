#!/usr/bin/env python3
"""``bridge`` — operator CLI for the Bridge box.

    bridge account create <label> [--token-file PATH]
    bridge account list
    bridge account revoke <label|id>
    bridge device list [--account <label|id>]
    bridge device purge <account> <device>
    bridge job enqueue <account> <device> <capability> [params-json] [--no-push]
    bridge job get <id>
    bridge job wait <id> [--timeout 120]
    bridge push <account> <device> [--kind poll|sync]
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
        meta = db.unjson(row["meta"]) or {}
        caps = ",".join(meta.get("capabilities") or []) or "-"
        print(f"{row['account_id']}  {row['device_id']:<16} last_seen {row['last_seen']}  "
              f"apns {'yes' if row['apns_token'] else 'no'}  "
              f"app {meta.get('app_version') or '-'}  caps {caps}")


def cmd_device_purge(conn, args):
    account = resolve_account(conn, args.account)
    counts = db.purge_device(conn, account["id"], args.device)
    print(f"purged device {args.device} of account {account['label']}: "
          f"jobs {counts['jobs']} (results {counts['results']}), "
          f"audit {counts['audit']}, device rows {counts['devices']}")


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
