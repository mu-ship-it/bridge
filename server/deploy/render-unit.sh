#!/bin/sh
# Write deploy/bridge.service from the tracked template, with this box's paths.
#
#   ./deploy/render-unit.sh            # paths taken from where this checkout lives
#   BRIDGE_DIR=/opt/bridge ./deploy/render-unit.sh
#
# The rendered unit is deliberately NOT tracked: a public repo carries no host paths.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_DIR="${BRIDGE_DIR:-$here}"
DATA_DIR="${DATA_DIR:-$(dirname "$(awk -F= '/^BRIDGE_DB=/{print $2}' "${BRIDGE_ENV_FILE:-$HOME/.config/bridge/env}" 2>/dev/null | tail -1)")}"
[ "$DATA_DIR" = "." ] && DATA_DIR="$HOME/bridge-data"
sed -e "s|__BRIDGE_DIR__|$BRIDGE_DIR|g" -e "s|__DATA_DIR__|$DATA_DIR|g" \
    "$here/deploy/bridge.service.example" > "$here/deploy/bridge.service"
echo "wrote $here/deploy/bridge.service (BRIDGE_DIR=$BRIDGE_DIR DATA_DIR=$DATA_DIR)"
