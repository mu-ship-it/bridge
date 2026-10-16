#!/bin/sh
# systemd entry point. Config comes from ~/.config/bridge/env (see README.md), never from here.
set -eu
cd "$(dirname "$0")"
exec ./.venv/bin/python app.py
