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
  echo "Install these manually: bash tar pigz rsync curl coreutils docker"
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

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "WARNING: Docker is not installed. backup.sh needs Docker to stop/start containers."
  echo "Install Docker: https://docs.docker.com/engine/install/"
fi

# Set up .env if not present
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  echo
  echo "No .env found. Copying .env.example to .env..."
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"

  # Auto-detect Postgres databases and write to .env
  if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
    echo
    echo "=== Postgres auto-detection ==="
    PG_RESULT=$("$SCRIPT_DIR/discover.sh" --quiet 2>/dev/null || true)
    if [[ -n "$PG_RESULT" ]]; then
      sed -i "s|^PG_DUMP_DBS=.*|PG_DUMP_DBS=${PG_RESULT}|" "$SCRIPT_DIR/.env"
      echo "Found Postgres databases, wrote to .env:"
      echo "  PG_DUMP_DBS=$PG_RESULT"
    else
      echo "No Postgres databases found. PG_DUMP_DBS left empty."
    fi
  fi

  echo
  echo "Edit $SCRIPT_DIR/.env with your settings before running the backup."
else
  echo
  echo ".env already exists, skipping."
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR/backup.sh" "$SCRIPT_DIR/discover.sh" "$SCRIPT_DIR/uninstall.sh"

# Offer cron setup
echo
echo "=== Cron setup ==="
echo "Want to schedule nightly backups at 2:00 AM? (y/N)"
read -r REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  CRON_LINE="0 2 * * * cd $SCRIPT_DIR && ./backup.sh >> $SCRIPT_DIR/logs/cron.log 2>&1"
  (crontab -l 2>/dev/null | grep -v "casaos-backup"; echo "$CRON_LINE") | crontab -
  echo "Cron job added:"
  echo "  $CRON_LINE"
else
  echo "Skipped. You can add it later — see examples/crontab.example"
fi

echo
echo "=== Done ==="
echo "Next steps:"
echo "  1. Edit .env with your Telegram token, chat ID, NAS path, etc."
echo "  2. Test: sudo ./backup.sh"
echo "  3. Check your Telegram for the notification."
