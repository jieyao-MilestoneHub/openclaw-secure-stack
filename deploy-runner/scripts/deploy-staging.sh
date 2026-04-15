#!/bin/sh
set -eu

# deploy-staging.sh — narrowed bridge: only deploys finantial-chatbot to staging
# No parameters accepted. Runs a fixed, predetermined deployment sequence.
# Production deployment is NOT available through this script.

CONTAINER="openclaw-deploy-runner"
LOG_DIR="/app/logs"
TIMESTAMP="$(date -Iseconds)"

echo "[deploy-staging] started at $TIMESTAMP"

# --- Fixed deployment steps (fill in when ready) ---
# All steps are hardcoded — no user-supplied arguments reach the container.

docker exec "$CONTAINER" sh -c '
  echo "[deploy-staging] running fixed staging deployment"
  echo "target=staging"
  echo "project=finantial-chatbot"
  # TODO: replace with actual staging deploy commands, e.g.:
  #   cd /app/artifacts && ./deploy.sh staging
  echo "[deploy-staging] placeholder — no real deployment configured yet"
'

echo "[deploy-staging] finished at $(date -Iseconds)"
