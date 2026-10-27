"""Configuration for the Bridge server.

Nothing secret and nothing host-specific lives in this repo. Every value comes from the
environment, or from an operator-owned env file (default ``~/.config/bridge/env``) that is
never committed. See README.md for the file's shape.

Precedence: real environment variable > env file > built-in default.
"""
import os
from pathlib import Path

ENV_FILE = Path(os.environ.get("BRIDGE_ENV_FILE", "~/.config/bridge/env")).expanduser()

DEFAULTS = {
    # Out-of-tree on purpose (house rule "DB-IN-TREE"): a checkout must never carry data.
    "BRIDGE_DB": str(Path("~/bridge-data/bridge.db").expanduser()),
    "BRIDGE_LISTEN": "127.0.0.1:8798",
    # Job loop knobs. The lease length is the one the phone contract suggests (docs/API.md).
    "BRIDGE_LEASE_SECONDS": "120",
    "BRIDGE_MAX_ATTEMPTS": "3",
    "BRIDGE_POLL_AFTER_SECONDS": "30",
    "BRIDGE_MAX_JOBS_PER_POLL": "20",
    # Signed .shortcut files the phone may import (server/tools/make_shortcut.py --sign -o here).
    "BRIDGE_SHORTCUTS_DIR": str(Path("~/bridge-data/shortcuts").expanduser()),
    # APNs is optional. Unset = pushes become a logged no-op; everything else still works.
    "APNS_KEY_PATH": "",
    "APNS_KEY_ID": "",
    "APNS_TEAM_ID": "",
    "APNS_TOPIC": "",
    "APNS_SANDBOX": "0",
    # The desk display's weather spot (Open-Meteo, no key). Default: Shenyang.
    "BRIDGE_WEATHER_LAT": "41.80",
    "BRIDGE_WEATHER_LON": "123.43",
    "BRIDGE_WEATHER_PLACE": "Shenyang",
}

_file_env = None


def _from_file():
    """Parse the env file once. Lines are ``KEY=value``; ``#`` comments and blanks ignored."""
    global _file_env
    if _file_env is None:
        _file_env = {}
        try:
            text = ENV_FILE.read_text()
        except OSError:
            return _file_env
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.startswith("export "):
                key = key[len("export "):]
            _file_env[key.strip()] = value.strip().strip('"').strip("'")
    return _file_env


def get(key, default=None):
    value = os.environ.get(key)
    if value is None:
        value = _from_file().get(key)
    if value is None or value == "":
        value = DEFAULTS.get(key, default)
    return value


def get_int(key):
    return int(get(key))


def get_bool(key):
    return str(get(key)).strip().lower() in ("1", "true", "yes", "on")


def listen():
    host, _, port = str(get("BRIDGE_LISTEN")).rpartition(":")
    return (host or "127.0.0.1"), int(port)


def db_path():
    return Path(str(get("BRIDGE_DB"))).expanduser()


def apns_configured():
    return all(get(k) for k in ("APNS_KEY_PATH", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC"))
