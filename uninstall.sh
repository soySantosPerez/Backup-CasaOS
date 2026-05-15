#!/usr/bin/env bash
# casaos-backup — uninstaller
# Removes the cron job and optionally the project directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== casaos-backup uninstaller ==="
echo

# Remove cron job
EXISTING_CRON=$(crontab -l 2>/dev/null || true)
if echo "$EXISTING_CRON" | grep -q "casaos-backup\|backup\.sh"; then
  echo "Removing cron job..."
  echo "$EXISTING_CRON" | grep -v "casaos-backup\|backup\.sh" | crontab -
  echo "Cron job removed."
else
  echo "No casaos-backup cron job found."
fi

# Remove logs
if [[ -d "$SCRIPT_DIR/logs" ]]; then
  echo
  echo "Remove local logs? (y/N)"
  read -r REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    rm -rf "$SCRIPT_DIR/logs"
    echo "Logs removed."
  else
    echo "Logs kept."
  fi
fi

# Remove .env (contains secrets)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  echo
  echo "Remove .env? (contains your tokens) (y/N)"
  read -r REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    rm -f "$SCRIPT_DIR/.env"
    echo ".env removed."
  else
    echo ".env kept."
  fi
fi

# Offer to remove the entire directory
echo
echo "Remove the entire casaos-backup directory? ($SCRIPT_DIR) (y/N)"
read -r REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Removing $SCRIPT_DIR..."
  rm -rf "$SCRIPT_DIR"
  echo "Done. casaos-backup has been fully removed."
else
  echo "Directory kept. You can delete it manually later."
fi

echo
echo "=== Uninstall complete ==="
echo "Your backups on the NAS were NOT touched."
