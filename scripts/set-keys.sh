#!/bin/sh
#
# scripts/set-keys.sh — write API keys / tokens into the right places.
#
# Usage:
#   scripts/set-keys.sh --codex    <CODEX_API_KEY>          # codex-worker/.env
#   scripts/set-keys.sh --gateway  <OPENAI_API_KEY>         # gateway/.env
#   scripts/set-keys.sh --telegram                          # reads from stdin
#   scripts/set-keys.sh --telegram -                        # reads from stdin
#
# You may combine flags: -c KEY1 -g KEY2 -t will update all three.
# Missing flags are left untouched.
#
# Env-var form (safer, keeps the value out of argv / `ps` / shell history):
#   CODEX_API_KEY=sk-...  OPENAI_API_KEY=sk-...  TELEGRAM_BOT_TOKEN=123:abc \
#     scripts/set-keys.sh
#
# SECURITY NOTES
# - Arguments passed as flags appear in `ps -ef`, in your shell history,
#   and possibly in audit logs. For production rotation, prefer the
#   env-var form above, or run with `--telegram` (or `-t`) with no value
#   so the token is read from stdin (hidden input is your caller's
#   responsibility, e.g. `read -rs VAR && TELEGRAM_BOT_TOKEN=$VAR ...`).
# - This script never echoes the actual value. Its output is limited to
#   byte counts, file modes, and gitignore status.
# - Files are written with mode 600.
# - The codex-worker container is restarted automatically so a new
#   CODEX_API_KEY takes effect. The gateway container is NOT restarted
#   even when --telegram is used, because enabling Telegram is a
#   separately-reviewed step (see HARDENING.md).
#
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEX_ENV="$REPO_ROOT/codex-worker/.env"
GATEWAY_ENV="$REPO_ROOT/gateway/.env"
OPENCLAW_JSON_IN_CONTAINER="/home/node/.openclaw/openclaw.json"
GATEWAY_CONTAINER="openclaw-gateway"

codex_key="${CODEX_API_KEY:-}"
gateway_key="${OPENAI_API_KEY:-}"
telegram_token="${TELEGRAM_BOT_TOKEN:-}"
read_telegram_from_stdin=no

usage() {
    cat <<USAGE
Usage: $0 [--codex|-c <KEY>] [--gateway|-g <KEY>] [--telegram|-t [-]]

  --codex    / -c VALUE    write CODEX_API_KEY to codex-worker/.env
  --gateway  / -g VALUE    write OPENAI_API_KEY to gateway/.env
  --telegram / -t [ - ]    write channels.telegram.botToken into the
                           gateway's openclaw.json; reads from stdin
                           (or \$TELEGRAM_BOT_TOKEN if set).

Env-var form:
  CODEX_API_KEY / OPENAI_API_KEY / TELEGRAM_BOT_TOKEN

All three are optional; at least one must be supplied.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--codex)
            shift
            [ $# -gt 0 ] || { echo "ERROR: --codex requires a value" >&2; exit 2; }
            codex_key="$1"
            shift
            ;;
        -g|--gateway)
            shift
            [ $# -gt 0 ] || { echo "ERROR: --gateway requires a value" >&2; exit 2; }
            gateway_key="$1"
            shift
            ;;
        -t|--telegram)
            # If the next arg is '-' or missing, read from stdin.
            # Otherwise accept it as the value (discouraged; visible in ps).
            if [ $# -ge 2 ] && [ "$2" != "-" ] && ! printf '%s' "$2" | grep -q '^-'; then
                telegram_token="$2"
                shift 2
            else
                read_telegram_from_stdin=yes
                [ $# -ge 2 ] && [ "$2" = "-" ] && shift
                shift
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$read_telegram_from_stdin" = "yes" ] && [ -z "$telegram_token" ]; then
    # Read one line from stdin, then strip trailing whitespace.
    if [ -t 0 ]; then
        printf 'Paste Telegram botToken and press Enter (input is visible): ' >&2
    fi
    IFS= read -r telegram_token || telegram_token=""
fi

if [ -z "$codex_key" ] && [ -z "$gateway_key" ] && [ -z "$telegram_token" ]; then
    echo "ERROR: nothing to do. Provide --codex and/or --gateway and/or --telegram." >&2
    usage >&2
    exit 2
fi

write_env() {
    # write_env <path> <varname> <value>
    path="$1"; name="$2"; value="$3"
    dir="$(dirname "$path")"
    [ -d "$dir" ] || { echo "ERROR: directory $dir does not exist" >&2; exit 1; }
    umask 077
    printf '%s=%s\n' "$name" "$value" > "$path"
    chmod 600 "$path"
    echo "wrote $path ($(stat -c %s "$path") bytes, mode $(stat -c %a "$path"))"
}

verify_gitignored() {
    path="$1"
    rel="${path#"$REPO_ROOT/"}"
    if ! (cd "$REPO_ROOT" && git check-ignore -q "$rel" 2>/dev/null); then
        echo "WARNING: $rel is NOT covered by .gitignore — check your .gitignore" >&2
        return 1
    fi
    return 0
}

# Basic sanity check: OpenAI-style keys start with "sk-". We don't enforce
# it because providers change formats, but we warn so typos surface early.
warn_openai_format() {
    name="$1"; value="$2"
    case "$value" in
        sk-*) ;;
        *) echo "WARNING: $name does not start with 'sk-' — double-check the value" >&2 ;;
    esac
    if [ "${#value}" -lt 20 ]; then
        echo "WARNING: $name is suspiciously short (${#value} chars)" >&2
    fi
}

# Telegram tokens look like "<9-10 digit bot id>:<~35 char body>".
warn_telegram_format() {
    value="$1"
    case "$value" in
        [0-9]*:*) ;;
        *) echo "WARNING: Telegram botToken does not match <id>:<body> shape" >&2 ;;
    esac
    if [ "${#value}" -lt 30 ] || [ "${#value}" -gt 80 ]; then
        echo "WARNING: Telegram botToken length ${#value} is outside 30..80 — double-check" >&2
    fi
}

# Write botToken into openclaw.json inside the gateway container. The value
# is piped over stdin to the in-container Python process so it never appears
# in argv / docker exec command line / ps listing.
set_telegram_token() {
    value="$1"
    if ! docker ps --format '{{.Names}}' | grep -q "^${GATEWAY_CONTAINER}\$"; then
        echo "ERROR: container ${GATEWAY_CONTAINER} is not running" >&2
        exit 1
    fi
    printf '%s' "$value" | docker exec -i "$GATEWAY_CONTAINER" python3 -c '
import json, os, sys, tempfile
path = "'"$OPENCLAW_JSON_IN_CONTAINER"'"
token = sys.stdin.read()
with open(path, "r") as f:
    cfg = json.load(f)
cfg.setdefault("channels", {}).setdefault("telegram", {})["botToken"] = token
fd, tmp = tempfile.mkstemp(prefix=".openclaw.json.", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.remove(tmp)
' \
        && echo "wrote ${GATEWAY_CONTAINER}:${OPENCLAW_JSON_IN_CONTAINER} (botToken field; value not echoed)"
}

if [ -n "$codex_key" ]; then
    warn_openai_format CODEX_API_KEY "$codex_key"
    write_env "$CODEX_ENV" CODEX_API_KEY "$codex_key"
    verify_gitignored "$CODEX_ENV" || true
    restart_codex=yes
fi

if [ -n "$gateway_key" ]; then
    warn_openai_format OPENAI_API_KEY "$gateway_key"
    write_env "$GATEWAY_ENV" OPENAI_API_KEY "$gateway_key"
    verify_gitignored "$GATEWAY_ENV" || true
fi

if [ -n "$telegram_token" ]; then
    warn_telegram_format "$telegram_token"
    set_telegram_token "$telegram_token"
fi

# Wipe local copies from this process's memory ASAP.
codex_key=""; gateway_key=""; telegram_token=""
unset codex_key gateway_key telegram_token TELEGRAM_BOT_TOKEN

# Rebuild the project-root .env that `docker compose` reads for variable
# interpolation. Canonical per-service .env files stay authoritative; this
# file is derived from them. Never edit it by hand.
rebuild_root_env() {
    root_env="$REPO_ROOT/.env"
    if [ -L "$root_env" ]; then
        rm -f "$root_env"
    fi
    umask 077
    : > "$root_env"
    chmod 600 "$root_env"
    if [ -r "$REPO_ROOT/bridge/.env" ]; then
        grep -E '^BRIDGE_TOKEN=' "$REPO_ROOT/bridge/.env" >> "$root_env" || true
    fi
    if [ -r "$REPO_ROOT/gateway/.env" ]; then
        grep -E '^OPENAI_API_KEY=' "$REPO_ROOT/gateway/.env" >> "$root_env" || true
    fi
    echo "rebuilt $root_env ($(wc -l < "$root_env") vars)"
}

rebuild_root_env

if [ "${restart_codex:-no}" = "yes" ]; then
    echo "restarting codex-worker to pick up new CODEX_API_KEY..."
    (cd "$REPO_ROOT" && docker compose restart codex-worker) >/dev/null
    sleep 2
    if docker ps --format '{{.Names}} {{.Status}}' | grep -q '^openclaw-codex-worker Up'; then
        echo "codex-worker is Up"
    else
        echo "ERROR: codex-worker is not Up after restart" >&2
        exit 1
    fi
fi

echo "done."
