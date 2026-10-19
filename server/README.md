# Bridge box — the server side

The phone app in this repo is a client of *your* server. This is a reference server for it:
a small FastAPI app that implements [`docs/API.md`](../docs/API.md) — a job queue the phone
polls, a place for it to post results, and an optional silent push to nudge it to poll sooner.

It is deliberately boring: Python 3 + SQLite, one file per concern, no background workers, no
message broker. One box with a few phones on it will never need more.

```
server/
  app.py              FastAPI app — the four endpoints the phone talks to, plus /bridge/health
  db.py               SQLite schema and every query (all of them scoped by account)
  apns.py             optional silent push
  cli.py, bridge      the `bridge` operator CLI
  run.sh              systemd entry point
  tools/mock_phone.py a fake iPhone, for a round trip without an iPhone
  tools/smoke.sh      end-to-end check against a deployed server
  tests/              pytest, always against a throwaway database
  deploy/             caddy snippet + systemd unit template
```

## What it guarantees

**Multi-tenant from day one.** Every row belongs to an account. A token is per account, stored
only as a sha256 digest and compared constant-time; revoking an account kills its token
immediately. A device id is unique only *within* an account, so two tenants can both call their
phone `my-iphone` and never see each other's jobs. There is no cross-tenant sharing today; when
it is needed it will be an explicit grant table, not a loosened query.

**Audit-ready.** Every authenticated call — and every rejected one — appends a row to `audit`:
timestamp, account, device, endpoint, outcome. Never a request body, never a result, never a
token. A trigger blocks `UPDATE` on that table. The one path that deletes audit rows is
`bridge device purge`, which exists precisely so that "delete everything you hold about this
device" is one command with a count you can show someone.

**Results are personal data.** A result can hold a heart rate series or a home address, so the
database and its WAL sidecars are created `0600`, the data directory `0700`, the service runs
with `UMask=0077`, and the logs record ids and counts only.

**Nothing secret in the repo.** No tokens, no hostnames, no keys, no paths to either. All of it
comes from the config file below, which lives outside the checkout.

## Configuration

Everything is read from the environment, falling back to an operator-owned env file —
`~/.config/bridge/env` by default (`BRIDGE_ENV_FILE` points elsewhere). Create it `0600`:

```sh
# ~/.config/bridge/env    chmod 600
BRIDGE_DB=/var/lib/bridge/bridge.db      # out of the checkout, always
BRIDGE_LISTEN=127.0.0.1:8798             # behind a reverse proxy that terminates TLS
BRIDGE_LEASE_SECONDS=120
BRIDGE_MAX_ATTEMPTS=3
BRIDGE_POLL_AFTER_SECONDS=30
BRIDGE_SHORTCUTS_DIR=~/bridge-data/shortcuts   # signed .shortcut files served at /bridge/shortcuts/<slug>.shortcut

# APNs — all four needed for silent push; leave empty and push becomes a logged no-op.
APNS_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
APNS_TOPIC=org.example.Bridge            # your app's bundle id
APNS_SANDBOX=0                           # 1 forces the sandbox host for every device
```

The database must live **outside** the checkout. A deploy that overwrites the working tree must
never be able to take the data with it.

## Install

```sh
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
./deploy/render-unit.sh                 # writes deploy/bridge.service for this machine
```

`deploy/bridge.service` is generated, not tracked: a public repo carries no host paths. The
template is `deploy/bridge.service.example`; `render-unit.sh` fills in where the checkout and
the data directory actually live.

`deploy/bridge.caddy` is the reverse-proxy snippet:

```caddy
handle /bridge/* {
    reverse_proxy 127.0.0.1:8798
}
```

If the site in front of the box has its own auth (SSO, basic auth), **`/bridge/*` has to be
exempt from it** — the phone sends a Bridge bearer token and nothing else. A gate in front will
answer every request with its own 401 and the app will report "token rejected". The two 401s are
easy to tell apart: this server always answers `{"error": "unauthorized"}`.

Then start it however you start things; the unit is a plain `Type=simple` service running
`run.sh`.

## The `bridge` CLI

```sh
bridge account create <label> [--token-file PATH]   # the token is shown once, or written 600
bridge account list
bridge account revoke <label|id>
bridge devices [--account <label|id>]              # = device list; shows last_seen and duty on/off/stale
bridge device list [--account <label|id>]
bridge device purge <account> <device>              # erase everything about one device
bridge job enqueue <account> <device> <capability> [params-json] [--no-push]
bridge job get <id>
bridge job wait <id> [--timeout 120]                # exit 0 done, 1 failed, 3 timed out
bridge push <account> <device> [--kind poll|sync]
bridge events <account> [--device D] [--type T] [--since ID|ISO] [--limit 100] [--json]
bridge audit tail [--account X] [--device Y] [--limit 50]
```

`job enqueue` sends a silent push afterwards when APNs is configured and the device has
registered a token; otherwise it says so on stderr and the job simply waits for the next poll.
Either way the job is queued — push is a nudge, never the delivery mechanism.

## A full round trip with curl

Set up an account and a job on the box:

```sh
$ bridge account create demo
account demo (a_01J…) created
token (shown once, store it now):
brg_kqZ…
$ export TOKEN=brg_kqZ…  BOX=https://your-server.example  DEVICE=my-iphone

$ bridge job enqueue demo my-iphone health.query '{"metric":"hrv","interval":"hour"}'
j_01J9…
```

Now play the phone:

```sh
$ curl -s -H "Authorization: Bearer $TOKEN" "$BOX/bridge/ping?device=$DEVICE"
{"ok":true,"server_time":"2026-10-16T23:14:28Z"}

$ curl -s -X POST "$BOX/bridge/devices" -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -d '{
      "device":"my-iphone","apns_token":"<64 hex chars>","apns_environment":"production",
      "app_version":"0.5 (12)","capabilities":["device.info","health.query","location.now"]}'
{"ok":true}

$ curl -s -H "Authorization: Bearer $TOKEN" "$BOX/bridge/jobs?device=$DEVICE"
{"jobs":[{"id":"j_01J9…","capability":"health.query",
          "created_at":"2026-10-16T23:14:20Z","params":{"metric":"hrv","interval":"hour"}}],
 "poll_after_seconds":30}
```

That poll **leased** the job for `BRIDGE_LEASE_SECONDS`; polling again returns `{"jobs":[]}`
until the lease runs out. Post the result:

```sh
$ curl -s -X POST "$BOX/bridge/results" -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -d '{
      "device":"my-iphone","results":[{"job_id":"j_01J9…","ok":true,
        "result":{"metric":{"name":"heart_rate_variability","units":"ms","data":[]}},
        "started_at":"2026-10-16T23:14:25Z","finished_at":"2026-10-16T23:14:26Z"}]}'
{"ok":true,"accepted":1,"duplicate":0,"unknown":0,"invalid":0}

$ bridge job get j_01J9…      # status: done, with the phone's result
$ bridge device purge demo my-iphone
purged device my-iphone of account demo: jobs 1 (results 1), audit 4, device rows 1
```

Delivery is at-least-once: if the phone dies holding a lease, the job goes back to the queue
when the lease expires, and after `BRIDGE_MAX_ATTEMPTS` tries it is marked `failed` with
`{"code":"timeout"}`. A second result for a job that already finished is ignored, by contract.

## Without an iPhone

`tools/mock_phone.py` is the mirror image of the repo's `tools/mock_box.py` — that one fakes the
box for the real app, this one fakes the app for the real box. Stdlib only:

```sh
python3 tools/mock_phone.py --url "$BOX" --token "$TOKEN" --device my-iphone \
    --register --ping --once          # drop --once to keep polling every 5 s
```

It answers `device.info`, `location.now` and `health.query` with synthetic data and reports
`unknown_capability` for anything else, exactly as the app would. `--header 'K: V'` adds a
header, for a box behind a proxy that wants its own auth.

## Checking a deployment

```sh
tools/smoke.sh https://your-server.example
```

Creates a throwaway account, walks the whole contract (auth, registration, enqueue, lease,
duplicate suppression, result, read-back, audit, purge), revokes the account and checks the dead
token is refused. 27 checks; it prints a `PASS:`/`FAIL:` line each and exits non-zero on any
failure. The token lives in a `0600` temp file and is never printed.

## Tests

```sh
.venv/bin/python -m pytest        # from server/
```

The suite **refuses to run** unless `BRIDGE_DB` points inside the system temp directory — tests
are never allowed near a live database. Each test gets its own fresh file.

## Silent push

Push needs an APNs auth key (`.p8`) from your Apple developer account, its key id, your team id,
and your app's bundle id as the topic. With those four set, `bridge job enqueue` and
`bridge push` send `{"aps":{"content-available":1},"bridge":"poll"}` with `apns-push-type:
background` and `apns-priority: 5`. A device that registered with
`"apns_environment": "development"` is pushed via Apple's sandbox host automatically.

iOS throttles background pushes to a few an hour and may drop them entirely, so treat a push as
"poll sooner if you feel like it". The queue, not the push, is what makes a job arrive.
