#!/bin/sh
# run-codex.sh (gateway-side client) — forwards prompt to openclaw-bridge.
# The real hardened worker script lives at /opt/openclaw-stack/bridge/scripts/run-codex.sh
# inside the bridge container; this one only does a single HTTP POST.
set -eu
exec node /home/node/.openclaw/bridge-client.js run-codex "${1:-}"
