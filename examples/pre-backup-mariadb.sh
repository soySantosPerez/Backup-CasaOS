#!/usr/bin/env bash
# Example PRE_BACKUP_CMD: dump every database of a MariaDB container to a
# compressed SQL file, so the backup holds a consistent copy instead of the
# live InnoDB files.
#
# Usage in .env:
#   PRE_BACKUP_CMD="/path/to/pre-backup-mariadb.sh mariadb /opt/stacks/infra-db/dumps"
#
# The root password is read from the container's own MARIADB_ROOT_PASSWORD,
# so it never has to be written here or in .env.

set -euo pipefail

CONTAINER="${1:?usage: $0 <container> <dump_dir>}"
DUMP_DIR="${2:?usage: $0 <container> <dump_dir>}"

umask 077
mkdir -p "$DUMP_DIR"
TMP="${DUMP_DIR}/.all-databases.sql.gz.tmp"

docker exec "$CONTAINER" sh -c \
  'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --all-databases --single-transaction --routines --events' \
  | gzip -6 > "$TMP"

mv "$TMP" "${DUMP_DIR}/all-databases.sql.gz"
echo "Dump OK: ${DUMP_DIR}/all-databases.sql.gz ($(du -h "${DUMP_DIR}/all-databases.sql.gz" | cut -f1))"
