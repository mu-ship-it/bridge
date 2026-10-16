"""Silent push to the phone (box -> APNs -> phone). Optional by design.

docs/API.md: the payload is ``{"aps": {"content-available": 1}, "bridge": "poll"}`` with
``apns-push-type: background`` and ``apns-priority: 5``. iOS throttles these heavily, so a push
is a nudge to poll sooner, never the delivery mechanism — the job still sits in the queue.

If the APNs settings are missing the push becomes a logged no-op and enqueueing still works
(Mu's constraint 3), so a fresh install is useful before anyone touches an Apple developer account.
"""
import json
import logging
import time
from pathlib import Path

import config

log = logging.getLogger("bridge.apns")

PROD_HOST = "https://api.push.apple.com"
SANDBOX_HOST = "https://api.sandbox.push.apple.com"
_token_cache = {"jwt": None, "issued": 0.0}


class PushOutcome:
    """Small result object so callers can log an outcome without caring how push went."""

    def __init__(self, sent, detail, status=None):
        self.sent = sent
        self.detail = detail
        self.status = status

    @property
    def outcome(self):
        return f"push:{self.detail}" + (f":{self.status}" if self.status else "")

    def __repr__(self):
        return f"<PushOutcome sent={self.sent} detail={self.detail} status={self.status}>"


def _provider_jwt():
    """ES256 provider token, reused for an hour (Apple rejects tokens minted too often)."""
    import jwt  # imported lazily so the server runs even without PyJWT present

    if _token_cache["jwt"] and time.time() - _token_cache["issued"] < 3000:
        return _token_cache["jwt"]
    key = Path(str(config.get("APNS_KEY_PATH"))).expanduser().read_text()
    token = jwt.encode(
        {"iss": config.get("APNS_TEAM_ID"), "iat": int(time.time())},
        key,
        algorithm="ES256",
        headers={"kid": config.get("APNS_KEY_ID")},
    )
    _token_cache.update({"jwt": token, "issued": time.time()})
    return token


def host_for(environment):
    if config.get_bool("APNS_SANDBOX") or (environment or "").lower().startswith("dev"):
        return SANDBOX_HOST
    return PROD_HOST


def push(apns_token, environment=None, kind="poll"):
    """Send one silent push. ``kind`` is "poll" or "sync" (see docs/API.md)."""
    if not config.apns_configured():
        log.info("push skipped: APNs not configured (enqueue still works)")
        return PushOutcome(False, "unconfigured")
    if not apns_token:
        log.info("push skipped: device has no APNs token yet")
        return PushOutcome(False, "no_device_token")

    import httpx  # lazy: keeps the import cost off the request path when APNs is unused

    payload = {"aps": {"content-available": 1}, "bridge": kind}
    url = f"{host_for(environment)}/3/device/{apns_token}"
    headers = {
        "authorization": f"bearer {_provider_jwt()}",
        "apns-push-type": "background",
        "apns-priority": "5",
        "apns-topic": str(config.get("APNS_TOPIC")),
    }
    try:
        with httpx.Client(http2=True, timeout=10) as client:
            response = client.post(url, headers=headers, content=json.dumps(payload))
    except Exception as exc:  # network, TLS, bad key — never fatal to the caller
        log.warning("push failed: %s", type(exc).__name__)
        return PushOutcome(False, "error")
    if response.status_code == 200:
        log.info("push sent (apns-id %s)", response.headers.get("apns-id", "?"))
        return PushOutcome(True, "sent", 200)
    # Apple's body is a short reason string like {"reason":"BadDeviceToken"} — safe to log.
    log.warning("push rejected %s %s", response.status_code, response.text[:120])
    return PushOutcome(False, "rejected", response.status_code)
