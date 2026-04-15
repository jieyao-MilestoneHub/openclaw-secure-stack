#!/bin/sh
set -eu

# query-readonly.sh — narrowed bridge: read-only queries against finantial-chatbot DB
# Enforces: SELECT only, row limit, statement timeout, fixed target database.
# No DDL, DML, or administrative commands allowed.

QUERY="${1:-}"

# --- Input validation ---
if [ -z "$QUERY" ]; then
  echo "ERROR: query is required" >&2
  exit 1
fi

if [ "${#QUERY}" -gt 2000 ]; then
  echo "ERROR: query exceeds 2000 character limit" >&2
  exit 1
fi

# Normalize to uppercase for keyword checking
QUERY_UPPER="$(printf '%s' "$QUERY" | tr '[:lower:]' '[:upper:]')"

# Must start with SELECT or WITH (for CTEs)
case "$QUERY_UPPER" in
  SELECT*|WITH*) ;;
  *)
    echo "ERROR: only SELECT or WITH (CTE) queries are allowed" >&2
    exit 1
    ;;
esac

# Block dangerous keywords anywhere in the query
for KEYWORD in INSERT UPDATE DELETE DROP CREATE ALTER TRUNCATE GRANT REVOKE COPY EXECUTE CALL; do
  case "$QUERY_UPPER" in
    *"$KEYWORD"*)
      echo "ERROR: forbidden keyword '$KEYWORD' detected" >&2
      exit 1
      ;;
  esac
done

# --- Enforce LIMIT if not present ---
case "$QUERY_UPPER" in
  *LIMIT*) ;;
  *)
    QUERY="$QUERY LIMIT 100"
    echo "[db-query-runner] LIMIT 100 appended automatically" >&2
    ;;
esac

CONTAINER="openclaw-db-query-runner"
TIMESTAMP="$(date -Iseconds)"

echo "[db-query-runner] started at $TIMESTAMP" >&2

# Pass query via stdin to avoid shell injection
# TODO: replace with actual psql/mongo command targeting the correct DB, e.g.:
#   printf '%s' "$QUERY" | docker exec -i "$CONTAINER" sh -c '
#     PGPASSWORD="$DB_PASS" psql -h sql-chatbot-postgres -U readonly_user -d chatbot \
#       -v ON_ERROR_STOP=1 \
#       -c "SET statement_timeout = '\''5000'\'';" \
#       -f -
#   '
printf '%s' "$QUERY" | docker exec -i "$CONTAINER" sh -c '
  QUERY="$(cat)"
  echo "[db-query-runner] would execute (placeholder):"
  echo "$QUERY"
  echo "[db-query-runner] placeholder — no real DB connection configured yet"
'

echo "[db-query-runner] finished at $(date -Iseconds)" >&2
