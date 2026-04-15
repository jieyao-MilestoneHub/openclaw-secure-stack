#!/bin/sh
# query-readonly.sh (gateway-side client) — forwards read-only SQL via bridge.
# Worker script is /opt/openclaw-stack/db-query-runner/scripts/query-readonly.sh.
set -eu
exec node /home/node/.openclaw/bridge-client.js query-readonly "${1:-}"
