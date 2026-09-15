#!/usr/bin/env sh
# One-shot pairing: run THIS yourself, then type the 6-digit code it prints into
# https://moonveil.pipicore.cn (console -> connectors -> pair device).
# Credentials land only in your local config file; nothing passes through chat.
set -eu
: "${MOONVEIL_CONNECTOR_HOME:=$HOME/.agents-anywhere-moonveil}"
export AGENT_CONNECTOR_DATA_DIR="$MOONVEIL_CONNECTOR_HOME"
mkdir -p "$MOONVEIL_CONNECTOR_HOME"; chmod 700 "$MOONVEIL_CONNECTOR_HOME"
cd "${MOONVEIL_CONNECTOR_SRC:-$HOME/aa-ios/conn-v200/connector}"
exec .venv/bin/anywhere-cli pair "${1:-https://moonveil.pipicore.cn}" \
  --config "$MOONVEIL_CONNECTOR_HOME/connector.json" --no-start
