#!/usr/bin/env bash
# casaos-backup — full CasaOS data backup
#
# Loads configuration from .env in the same directory as this script.
# See .env.example for all available variables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################
# Load .env
############################################

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  echo "ERROR: $SCRIPT_DIR/.env not found. Copy .env.example to .env and fill it in."
  exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/.env"

############################################
# Config and validation
############################################

: "${HOST_NAME:?HOST_NAME is required}"
: "${BACKUP_DEST:?BACKUP_DEST is required}"
: "${BACKUP_RETENTION:=3}"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"
: "${PATHS_TO_BACKUP:=/DATA,/var/lib/casaos}"

TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"
BACKUP_NAME="${HOST_NAME}_${TIMESTAMP}.tar.gz"
HOST_DEST="${BACKUP_DEST}/${HOST_NAME}-backups"
BACKUP_PATH="${HOST_DEST}/${BACKUP_NAME}"
WORK_DIR="/tmp/casaos-backup-$$"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="${LOG_DIR}/casaos-backup_${TIMESTAMP}.log"

mkdir -p "$WORK_DIR" "$LOG_DIR"

# Log to file and stdout simultaneously
exec > >(tee -a "$LOG_FILE") 2>&1

START_TS=$(date +%s)

############################################
# Helpers
############################################

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

bytes_to_human() {
  numfmt --to=iec-i --suffix=B --format="%.2f" "$1" 2>/dev/null || echo "${1}B"
}

tg_send() {
  local text="$1"
  local emoji="${2:-}"
  curl -sS --max-time 10 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${emoji} [${HOST_NAME}] ${text}" \
    -o /dev/null || log "WARN: telegram failed (no connectivity?)"
}

cleanup() {
  local exit_code=$?
  rm -rf "$WORK_DIR"
  exit "$exit_code"
}
trap cleanup EXIT

fail() {
  local msg="$1"
  log "ERROR: $msg"
  tg_send "Backup FAILED: $msg" "❌"
  exit 1
}

############################################
# Pre-flight checks
############################################

log "=== casaos-backup starting on ${HOST_NAME} ==="
log "Destination: ${BACKUP_PATH}"
log "Retention: ${BACKUP_RETENTION} backups"

if [[ ! -d "$BACKUP_DEST" ]]; then
  fail "BACKUP_DEST '$BACKUP_DEST' does not exist. Is the NAS mounted?"
fi
if ! touch "${BACKUP_DEST}/.write_test_$$" 2>/dev/null; then
  fail "No write permission on $BACKUP_DEST"
fi
rm -f "${BACKUP_DEST}/.write_test_$$"

mkdir -p "$HOST_DEST"

############################################
# Phase 1: compress
############################################

log "--- Phase 1: compressing ---"
TAR_LOCAL="${WORK_DIR}/${BACKUP_NAME}"

IFS=',' read -ra PATHS <<< "$PATHS_TO_BACKUP"
TAR_ARGS=()
for p in "${PATHS[@]}"; do
  p=$(echo "$p" | xargs)
  if [[ -e "$p" ]]; then
    TAR_ARGS+=("$p")
  else
    log "WARN: $p does not exist, skipping"
  fi
done

if [[ ${#TAR_ARGS[@]} -eq 0 ]]; then
  fail "No valid paths to back up"
fi

# Use pigz for multicore compression if available, fall back to gzip
if command -v pigz >/dev/null 2>&1; then
  COMPRESS="pigz -6 -p $(nproc)"
else
  log "WARN: pigz not found, falling back to gzip (slower)"
  COMPRESS="gzip -6"
fi

if ! tar --use-compress-program="$COMPRESS" \
         -cf "$TAR_LOCAL" \
         "${TAR_ARGS[@]}" 2>&1; then
  fail "tar failed"
fi

TAR_SIZE=$(stat -c %s "$TAR_LOCAL" 2>/dev/null || stat -f %z "$TAR_LOCAL")
log "Tar generated: $(bytes_to_human "$TAR_SIZE")"

############################################
# Phase 2: transfer to destination
############################################

log "--- Phase 2: moving backup to destination ---"
if ! rsync -a --partial --inplace "$TAR_LOCAL" "$BACKUP_PATH"; then
  fail "rsync to destination failed"
fi

# Verify size
REMOTE_SIZE=$(stat -c %s "$BACKUP_PATH" 2>/dev/null || stat -f %z "$BACKUP_PATH")
if [[ "$TAR_SIZE" != "$REMOTE_SIZE" ]]; then
  fail "Destination size ($REMOTE_SIZE) does not match local ($TAR_SIZE)"
fi
log "Verified: sizes match"

rm -f "$TAR_LOCAL"

############################################
# Phase 3: rotation (keep N most recent)
############################################

log "--- Phase 3: rotation ---"
mapfile -t ALL_BACKUPS < <(ls -1t "${HOST_DEST}"/${HOST_NAME}_*.tar.gz 2>/dev/null || true)
TOTAL=${#ALL_BACKUPS[@]}
log "Backups on destination: $TOTAL"

if [[ $TOTAL -gt $BACKUP_RETENTION ]]; then
  for ((i=BACKUP_RETENTION; i<TOTAL; i++)); do
    log "Deleting old: ${ALL_BACKUPS[$i]}"
    rm -f "${ALL_BACKUPS[$i]}"
  done
fi

############################################
# Summary
############################################

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))

SUMMARY="Backup OK
File: ${BACKUP_NAME}
Size: $(bytes_to_human "$TAR_SIZE")
Duration: ${DURATION_MIN}m ${DURATION_SEC}s
Retained: $(ls -1 "${HOST_DEST}"/${HOST_NAME}_*.tar.gz 2>/dev/null | wc -l)"

log "$SUMMARY"
tg_send "$SUMMARY" "✅"

log "=== Backup completed ==="
