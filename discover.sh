#!/usr/bin/env bash
# casaos-backup — discover Postgres containers and their databases
# Prints ready-to-paste values for PG_DUMP_DBS in your .env
#
# Usage:
#   ./discover.sh           Interactive mode with full output
#   ./discover.sh --quiet   Machine mode: prints only the PG_DUMP_DBS value (used by install.sh)

set -euo pipefail

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

if [[ "$QUIET" == false ]]; then
  echo "=== Searching for Postgres containers ==="
  echo
fi

# Find containers with postgres/pg in the image name
PG_CONTAINERS=$(docker ps --format '{{.Names}}\t{{.Image}}' | grep -i postgres || true)

if [[ -z "$PG_CONTAINERS" ]]; then
  if [[ "$QUIET" == false ]]; then
    echo "No running Postgres containers found."
    echo "If your database is stopped, start it first and run this again."
  fi
  exit 0
fi

ENTRIES=()

while IFS=$'\t' read -r NAME IMAGE; do
  [[ "$QUIET" == false ]] && echo "Found: $NAME ($IMAGE)"

  # Get the POSTGRES_USER from the container's environment
  PG_USER=$(docker exec "$NAME" sh -c 'echo ${POSTGRES_USER:-postgres}' 2>/dev/null || echo "postgres")

  [[ "$QUIET" == false ]] && echo "  User: $PG_USER"
  [[ "$QUIET" == false ]] && echo "  Databases:"

  DBS=$(docker exec "$NAME" psql -U "$PG_USER" -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null || true)

  if [[ -z "$DBS" ]]; then
    [[ "$QUIET" == false ]] && echo "    (could not list databases — check if the container accepts connections)"
    [[ "$QUIET" == false ]] && echo
    continue
  fi

  while IFS= read -r DB; do
    DB=$(echo "$DB" | xargs)
    [[ -z "$DB" ]] && continue
    [[ "$QUIET" == false ]] && echo "    - $DB"
    ENTRIES+=("${NAME}:${PG_USER}:${DB}")
  done <<< "$DBS"

  [[ "$QUIET" == false ]] && echo
done <<< "$PG_CONTAINERS"

if [[ ${#ENTRIES[@]} -gt 0 ]]; then
  RESULT=$(IFS=','; echo "${ENTRIES[*]}")
  if [[ "$QUIET" == true ]]; then
    echo "$RESULT"
  else
    echo "=== Ready to paste into your .env ==="
    echo
    echo "PG_DUMP_DBS=$RESULT"
    echo
  fi
else
  [[ "$QUIET" == false ]] && echo "No user databases found. You can leave PG_DUMP_DBS empty in your .env."
fi
