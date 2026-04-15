#!/bin/sh
#
# scripts/set-keys.sh — write API keys into the right per-service .env files.
#
# Usage:
#   scripts/set-keys.sh --codex <CODEX_API_KEY> --gateway <OPENAI_API_KEY>
#
# Either flag is optional; missing ones are left untouched. Short forms
# -c / -g also work. Example:
#   scripts/set-keys.sh -c sk-proj-abc... -g sk-proj-xyz...
#
# Alternatively, pass keys via env vars to keep them out of argv (safer
# because they don't appear in `ps` or shell history):
#   CODEX_API_KEY=sk-... OPENAI_API_KEY=sk-... scripts/set-keys.sh
#
# SECURITY NOTES
# - Arguments passed to this script appear in `ps -ef`, in your shell
#   history file, and potentially in audit logs. Prefer the env-var form
#   above, or use `read -rs` in your own wrapper. This script is a
#   convenience tool, not a secrets vault.
# - Files are written with mode 600 (owner read/write only) and placed
#   under paths already covered by .gitignore (*.env, .env*).
# - The codex-worker container is restarted automatically so the new
#   CODEX_API_KEY takes effect. The gateway container is NOT restarted
#   here, because enabling the gateway LLM is a separately-reviewed step.
#
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEX_ENV="$REPO_ROOT/codex-worker/.env"
GATEWAY_ENV="$REPO_ROOT/gateway/.env"

codex_key="${CODEX_API_KEY:-}"
gateway_key="${OPENAI_API_KEY:-}"

usage() {
    cat <<USAGE
Usage: $0 [--codex|-c <CODEX_API_KEY>] [--gateway|-g <OPENAI_API_KEY>]
       or set CODEX_API_KEY / OPENAI_API_KEY in the environment.

Writes:
  $CODEX_ENV       (if --codex or \$CODEX_API_KEY is provided)
  $GATEWAY_ENV     (if --gateway or \$OPENAI_API_KEY is provided)

Files are created with mode 600.
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

if [ -z "$codex_key" ] && [ -z "$gateway_key" ]; then
    echo "ERROR: nothing to do. Provide --codex and/or --gateway (or set env vars)." >&2
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
warn_format() {
    name="$1"; value="$2"
    case "$value" in
        sk-*) ;;
        *) echo "WARNING: $name does not start with 'sk-' — double-check the value" >&2 ;;
    esac
    if [ "${#value}" -lt 20 ]; then
        echo "WARNING: $name is suspiciously short (${#value} chars)" >&2
    fi
}

if [ -n "$codex_key" ]; then
    warn_format CODEX_API_KEY "$codex_key"
    write_env "$CODEX_ENV" CODEX_API_KEY "$codex_key"
    verify_gitignored "$CODEX_ENV" || true
    restart_codex=yes
fi

if [ -n "$gateway_key" ]; then
    warn_format OPENAI_API_KEY "$gateway_key"
    write_env "$GATEWAY_ENV" OPENAI_API_KEY "$gateway_key"
    verify_gitignored "$GATEWAY_ENV" || true
fi

# Wipe local copies from this process's memory ASAP.
codex_key=""; gateway_key=""
unset codex_key gateway_key

# Rebuild the project-root .env that `docker compose` reads for variable
# interpolation. Canonical per-service .env files stay authoritative; this
# file is derived from them. Never edit it by hand.
#
# Only BRIDGE_TOKEN (from bridge/.env) and OPENAI_API_KEY (from
# gateway/.env) need to be interpolated into compose — CODEX_API_KEY is
# passed into codex-worker via env_file: directly, so it stays out of
# the compose-level namespace.
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
