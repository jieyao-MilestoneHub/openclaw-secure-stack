#!/bin/sh
set -eu

# run-codex.sh — narrowed bridge: only runs codex exec inside finantial-chatbot workspace
# Called by OpenClaw gateway. Single-purpose: no arbitrary container, directory, or command.

PROMPT="${1:-}"
PREAMBLE_FILE="/scripts/codex-preamble.txt"

# --- Input validation (applied to user-supplied prompt only) ---
if [ -z "$PROMPT" ]; then
  echo "ERROR: prompt is required" >&2
  exit 1
fi

if [ "${#PROMPT}" -gt 4000 ]; then
  echo "ERROR: prompt exceeds 4000 character limit" >&2
  exit 1
fi

# --- Prepend fixed preamble (scope, tone, language, output budget) ---
# Preamble is mounted :ro from the host; the user-supplied prompt cannot
# replace or mutate it. If the file is missing we fail closed rather than
# run codex without the guardrail preamble.
if [ ! -r "$PREAMBLE_FILE" ]; then
  echo "ERROR: codex preamble file not readable: $PREAMBLE_FILE" >&2
  exit 1
fi
PREAMBLE="$(cat "$PREAMBLE_FILE")"
FULL_PROMPT="${PREAMBLE}
${PROMPT}"

# --- Execute in fixed container, fixed directory ---
# Pass prompt via stdin to avoid shell injection through argument expansion
printf '%s' "$FULL_PROMPT" | docker exec -i openclaw-codex-worker sh -lc '
  cd /workspace/finantial-chatbot &&
  PROMPT="$(cat)" &&
  codex exec --ephemeral --skip-git-repo-check "$PROMPT"
'
