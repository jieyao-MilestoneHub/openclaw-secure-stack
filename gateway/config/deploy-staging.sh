#!/bin/sh
# deploy-staging.sh (gateway-side client) — triggers fixed staging deploy via bridge.
# Zero parameters. Worker script is /opt/openclaw-stack/deploy-runner/scripts/deploy-staging.sh.
set -eu
exec node /home/node/.openclaw/bridge-client.js deploy-staging
