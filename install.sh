#!/usr/bin/env bash
# casaos-backup installer
# Installs dependencies and optionally sets up a cron job.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== casaos-backup installer ==="
echo

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt-get"
  INSTALL_CMD="sudo apt-get install -y"
elif command -v apk >/dev/null 2>&1; then
  PKG_MGR="apk"
  INSTALL_CMD="sudo apk add --no-cache"
else
  echo "ERROR: Could not detect package manager (apt-get or apk)."
  echo "Install these manually: bash tar pigz rsync curl coreutils"
  exit 1
fi

echo "Package manager: $PKG_MGR"
echo "Installing dependencies..."

if [[ "$PKG_MGR" == "apt-get" ]]; then
  sudo apt-get update -qq
  $INSTALL_CMD bash tar pigz rsync curl coreutils
else
  $INSTALL_CMD bash tar pigz rsync curl coreutils
fi

echo
echo "Dependencies installed."

# Set up .env if not present
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  echo
  echo "No .env found. Copying .env.example to .env..."
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  # If run with sudo, make .env owned by the real user so they can edit without sudo
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER:$SUDO_USER" "$SCRIPT_DIR/.env"
  fi
  echo
  echo "Edit $SCRIPT_DIR/.env with your settings before running the backup."
else
  echo
  echo ".env already exists, skipping."
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR/backup.sh" "$SCRIPT_DIR/uninstall.sh"

# Ensure logs directory is owned by the real user
mkdir -p "$SCRIPT_DIR/logs"
if [[ -n "${SUDO_USER:-}" ]]; then
  chown "$SUDO_USER:$SUDO_USER" "$SCRIPT_DIR/logs"
fi

# Offer cron setup
echo
echo "=== Cron setup ==="
echo "Want to schedule nightly backups at 2:00 AM? (y/N)"
read -r REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  CRON_LINE="0 2 * * * cd $SCRIPT_DIR && ./backup.sh >> $SCRIPT_DIR/logs/cron.log 2>&1"
  TMPFILE=$(mktemp)
  crontab -l 2>/dev/null | grep -v "backup\.sh" > "$TMPFILE" || true
  echo "$CRON_LINE" >> "$TMPFILE"
  crontab "$TMPFILE"
  rm -f "$TMPFILE"
  echo "Cron job added:"
  echo "  $CRON_LINE"
  echo
  echo "Verify with: crontab -l"
else
  echo "Skipped. You can add it later — see examples/crontab.example"
fi

echo
echo "=== Done ==="
echo "Next steps:"
echo "  1. Edit .env with your Telegram token, chat ID, NAS path, etc."
echo "  2. Test: sudo ./backup.sh"
echo "  3. Check your Telegram for the notification."
