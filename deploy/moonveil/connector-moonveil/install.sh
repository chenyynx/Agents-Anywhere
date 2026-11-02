#!/usr/bin/env sh
# Render the host-specific pm2 app definition into the live dir (never committed).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
sed "s#__HOME__#$HOME#g" "$here/ecosystem.json.example" > "${LIVE_DIR:-$HOME/moonveil-connector}/ecosystem.json"
chmod 600 "${LIVE_DIR:-$HOME/moonveil-connector}/ecosystem.json"
echo "wrote ${LIVE_DIR:-$HOME/moonveil-connector}/ecosystem.json"
