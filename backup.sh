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
: "${PRE_BACKUP_CMD:=}"
: "${HA_BACKUP_URL:=}"
: "${HA_BACKUP_WEBHOOK:=}"

TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"
BACKUP_NAME="${HOST_NAME}_${TIMESTAMP}.tar.gz"
HOST_DEST="${BACKUP_DEST}/${HOST_NAME}-backups"
BACKUP_PATH="${HOST_DEST}/${BACKUP_NAME}"
# The tar is written straight to the destination under a hidden name and
# renamed once verified, so nothing touches local storage (e.g. the SD card)
PARTIAL_PATH="${HOST_DEST}/.${BACKUP_NAME}.partial"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="${LOG_DIR}/casaos-backup_${TIMESTAMP}.log"

mkdir -p "$LOG_DIR"

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

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# Optional Home Assistant webhook; never blocks the backup or Telegram
ha_send() {
  local status="$1" message="${2:-}" size="${3:-null}" file="${4:-}"
  [[ -n "$HA_BACKUP_URL" && -n "$HA_BACKUP_WEBHOOK" ]] || return 0
  local json
  json=$(printf '{"host":"%s","status":"%s","size_bytes":%s,"duration_s":%s,"file":"%s","message":"%s"}' \
    "$(json_escape "$HOST_NAME")" "$status" "$size" "$(( $(date +%s) - START_TS ))" \
    "$(json_escape "$file")" "$(json_escape "$message")")
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' -d "$json" \
    "${HA_BACKUP_URL%/}/api/webhook/${HA_BACKUP_WEBHOOK}" \
    -o /dev/null || log "WARN: Home Assistant webhook failed"
}

cleanup() {
  local exit_code=$?
  rm -f "$PARTIAL_PATH"
  exit "$exit_code"
}
trap cleanup EXIT

fail() {
  local msg="$1"
  log "ERROR: $msg"
  tg_send "Backup FAILED: $msg" "❌"
  ha_send fail "$msg"
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
# Phase 0: pre-backup command (optional)
############################################

# e.g. dump databases to a path inside PATHS_TO_BACKUP, so the archive holds
# a consistent copy instead of live database files
if [[ -n "$PRE_BACKUP_CMD" ]]; then
  log "--- Phase 0: pre-backup command ---"
  log "Running: $PRE_BACKUP_CMD"
  if ! bash -o pipefail -c "$PRE_BACKUP_CMD"; then
    fail "PRE_BACKUP_CMD failed"
  fi
fi

############################################
# Phase 1: compress straight to destination
############################################

log "--- Phase 1: compressing to destination ---"

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
  TEST_CMD="pigz -t"
else
  log "WARN: pigz not found, falling back to gzip (slower)"
  COMPRESS="gzip -6"
  TEST_CMD="gzip -t"
fi

log "Compressing ${TAR_ARGS[*]} (this may take a while)..."
TAR_STDERR=$(mktemp)
if ! tar --use-compress-program="$COMPRESS" \
         -cf "$PARTIAL_PATH" \
         "${TAR_ARGS[@]}" 2>"$TAR_STDERR"; then
  TAR_ERR=$(grep -v "Removing leading" "$TAR_STDERR" | head -5)
  rm -f "$TAR_STDERR"
  fail "tar failed: $TAR_ERR"
fi
rm -f "$TAR_STDERR"

TAR_SIZE=$(stat -c %s "$PARTIAL_PATH" 2>/dev/null || stat -f %z "$PARTIAL_PATH")
log "Tar generated: $(bytes_to_human "$TAR_SIZE")"

############################################
# Phase 2: verify and finalize
############################################

log "--- Phase 2: verifying archive on destination ---"
# Reads the whole archive back from the destination
if ! $TEST_CMD "$PARTIAL_PATH"; then
  fail "Archive integrity check failed on destination"
fi
log "Verified: archive is intact"

if ! mv "$PARTIAL_PATH" "$BACKUP_PATH"; then
  fail "Could not rename archive to $BACKUP_PATH"
fi

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
ha_send ok "" "$TAR_SIZE" "$BACKUP_NAME"

log "=== Backup completed ==="
