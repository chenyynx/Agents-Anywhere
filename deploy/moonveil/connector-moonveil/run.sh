#!/usr/bin/env sh
# Moonveil connector — resident instance pointed at OUR cloud.
# Isolated from the official aa-connector by AGENT_CONNECTOR_DATA_DIR + --config.
set -eu
: "${MOONVEIL_CONNECTOR_HOME:=$HOME/.agents-anywhere-moonveil}"
export AGENT_CONNECTOR_DATA_DIR="$MOONVEIL_CONNECTOR_HOME"
export AGENT_SERVER_URL="${MOONVEIL_SERVER_URL:-https://moonveil.pipicore.cn}"
mkdir -p "$MOONVEIL_CONNECTOR_HOME"
chmod 700 "$MOONVEIL_CONNECTOR_HOME"
cd "${MOONVEIL_CONNECTOR_SRC:-$HOME/aa-ios/conn-v200/connector}"
exec .venv/bin/anywhere-cli start \
  --config "$MOONVEIL_CONNECTOR_HOME/connector.json" \
  --server-url "$AGENT_SERVER_URL"
