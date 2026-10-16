#!/usr/bin/env bash
# End-to-end smoke for a deployed Bridge box, driven entirely over HTTP.
#
#   server/tools/smoke.sh https://your-server.example
#   server/tools/smoke.sh http://127.0.0.1:8798
#
# It creates a throwaway account, walks the whole contract (ping, register, enqueue, lease,
# result, read-back, audit, purge), then revokes the account and checks the token is dead.
# The token is kept in a 600 temp file and never printed.
#
# If the site in front of the box gates every path (SSO, basic auth, …), export EXTRA_CURL
# with whatever gets you through, e.g.  EXTRA_CURL='-H "Cookie: session=..."'.
set -uo pipefail

BASE="${1:-http://127.0.0.1:8798}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$HERE/bridge"
DEVICE="${DEVICE:-smoke-iphone}"
LABEL="smoke-$(date +%s)-$$"
PASS=0; FAIL=0

work="$(mktemp -d)"; chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL: %s — %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1" "expected $3, got $2"; fi; }

# shellcheck disable=SC2086  # EXTRA_CURL is intentionally word-split
req() {  # req <method> <path> [body] -> prints "<http_code> <body>"
  local method="$1" path="$2" body="${3:-}" auth="${AUTH:-}"
  local args=(-s -w '\n%{http_code}' -X "$method" -H "Accept: application/json"
              -H "X-Bridge-Device: $DEVICE" -H "User-Agent: Bridge/0.1.0 (smoke)")
  [ -n "$auth" ] && args+=(-H "Authorization: Bearer $auth")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" -d "$body")
  local out; out="$(eval curl "${EXTRA_CURL:-}" '"${args[@]}"' "'$BASE$path'")"
  printf '%s %s' "$(printf '%s' "$out" | tail -1)" "$(printf '%s' "$out" | sed '$d' | tr -d '\n')"
}
code() { printf '%s' "$1" | cut -d' ' -f1; }
rest() { printf '%s' "$1" | cut -d' ' -f2-; }

say "=== Bridge smoke against $BASE ==="
say "--- account: a throwaway one, revoked at the end"
"$BRIDGE" account create "$LABEL" --token-file "$work/token" >/dev/null || { bad "account create"; exit 1; }
TOKEN="$(cat "$work/token")"
ok "throwaway account $LABEL created (token not shown)"

say "--- auth"
r="$(AUTH= req GET "/bridge/ping?device=$DEVICE")";       check "ping without a token" "$(code "$r")" 401
r="$(AUTH=brg_wrong req GET "/bridge/ping?device=$DEVICE")"; check "ping with a wrong token" "$(code "$r")" 401
r="$(AUTH=$TOKEN req GET "/bridge/ping?device=$DEVICE")"; check "ping with the token" "$(code "$r")" 200
case "$(rest "$r")" in *'"ok":true'*) ok "ping body has ok:true";; *) bad "ping body" "$(rest "$r")";; esac

say "--- device registration"
reg='{"device":"'"$DEVICE"'","apns_token":"'"$(printf '0%.0s' $(seq 64))"'","apns_environment":"development","app_version":"0.1.0 (1)","capabilities":["device.info","health.query","location.now"]}'
r="$(AUTH=$TOKEN req POST /bridge/devices "$reg")";       check "register device" "$(code "$r")" 200
"$BRIDGE" device list --account "$LABEL" | grep -q "$DEVICE" \
  && ok "device shows up in \`bridge device list\`" || bad "device list" "device missing"

say "--- enqueue, lease, result"
JOB="$("$BRIDGE" job enqueue "$LABEL" "$DEVICE" device.info 2>/dev/null)"
[ -n "$JOB" ] && ok "enqueued device.info ($JOB)" || bad "enqueue" "no job id"
r="$(AUTH=$TOKEN req GET "/bridge/jobs?device=$DEVICE")"; check "GET jobs" "$(code "$r")" 200
case "$(rest "$r")" in *"$JOB"*) ok "jobs poll handed over $JOB";; *) bad "jobs poll" "$(rest "$r")";; esac
case "$("$BRIDGE" job get "$JOB")" in *'"status": "leased"'*) ok "the poll leased the job";;
  *) bad "lease" "status is not leased";; esac
r="$(AUTH=$TOKEN req GET "/bridge/jobs?device=$DEVICE")"
case "$(rest "$r")" in *'"jobs":[]'*) ok "a leased job is not handed out twice";;
  *) bad "double lease" "$(rest "$r")";; esac

res='{"device":"'"$DEVICE"'","results":[{"job_id":"'"$JOB"'","ok":true,"result":{"battery_level":0.82,"model":"iPhone"},"started_at":"2026-01-01T00:00:01Z","finished_at":"2026-01-01T00:00:02Z"}]}'
r="$(AUTH=$TOKEN req POST /bridge/results "$res")";       check "POST results" "$(code "$r")" 200
case "$(rest "$r")" in *'"accepted":1'*) ok "result accepted";; *) bad "result" "$(rest "$r")";; esac
r="$(AUTH=$TOKEN req POST /bridge/results "$res")"
case "$(rest "$r")" in *'"duplicate":1'*) ok "a duplicate result is ignored";;
  *) bad "duplicate result" "$(rest "$r")";; esac
case "$("$BRIDGE" job get "$JOB")" in *'"status": "done"'*) ok "\`job get\` shows the job done";;
  *) bad "job get" "status is not done";; esac
case "$("$BRIDGE" job get "$JOB")" in *'0.82'*) ok "\`job get\` shows the phone's result";;
  *) bad "job get" "result body missing";; esac

say "--- audit"
audit="$("$BRIDGE" audit tail --account "$LABEL" --limit 50)"
for endpoint in "GET /bridge/ping" "POST /bridge/devices" "GET /bridge/jobs" "POST /bridge/results"; do
  printf '%s' "$audit" | grep -q "$endpoint" \
    && ok "audit row for $endpoint" || bad "audit" "no row for $endpoint"
done
printf '%s' "$audit" | grep -q "0.82" && bad "audit" "a result body leaked into audit" \
  || ok "audit holds no result bodies"

say "--- purge"
purged="$("$BRIDGE" device purge "$LABEL" "$DEVICE")"
say "    $purged"
case "$purged" in *"jobs 1"*) ok "purge removed the job";; *) bad "purge jobs" "$purged";; esac
case "$purged" in *"device rows 1"*) ok "purge removed the device";; *) bad "purge device" "$purged";; esac
[ -z "$("$BRIDGE" audit tail --account "$LABEL" --device "$DEVICE")" ] \
  && ok "purge removed the audit trail for that device" || bad "purge audit" "rows remain"
"$BRIDGE" job get "$JOB" >/dev/null 2>&1 && bad "purge job" "job still readable" \
  || ok "the job is gone"

say "--- revoke"
"$BRIDGE" account revoke "$LABEL" >/dev/null
r="$(AUTH=$TOKEN req GET "/bridge/ping?device=$DEVICE")"; check "revoked token is rejected" "$(code "$r")" 401

say ""
say "# Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
