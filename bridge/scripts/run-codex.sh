#!/bin/sh
set -eu

# run-codex.sh — narrowed bridge: only runs codex exec inside finantial-chatbot workspace
# Called by OpenClaw gateway. Single-purpose: no arbitrary container, directory, or command.

PROMPT="${1:-}"

# --- Input validation ---
if [ -z "$PROMPT" ]; then
  echo "ERROR: prompt is required" >&2
  exit 1
fi

# Max 4000 characters (codex prompt limit is generous, but cap to prevent abuse)
if [ "${#PROMPT}" -gt 4000 ]; then
  echo "ERROR: prompt exceeds 4000 character limit" >&2
  exit 1
fi

# --- Execute in fixed container, fixed directory ---
# Pass prompt via stdin to avoid shell injection through argument expansion
printf '%s' "$PROMPT" | docker exec -i openclaw-codex-worker sh -lc '
  cd /workspace/finantial-chatbot &&
  PROMPT="$(cat)" &&
  codex exec "$PROMPT"
'
