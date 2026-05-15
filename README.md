# casaos-backup

> Nightly CasaOS backups done right: stops containers, dumps Postgres, tars `/DATA`, uploads to NAS, pings you on Telegram.

A portable bash script that creates **consistent** backups of your CasaOS instance. It dumps Postgres databases first, stops running containers, archives `/DATA` and `/var/lib/casaos` into a single `tar.gz`, syncs it to a NAS, rotates retention, and notifies via Telegram when anything fails.

Runs directly on the host — no extra Docker container needed.

## Why

Born from a real incident: an SD card died on a Raspberry Pi running CasaOS, and recovery took eight hours of `ddrescue`, manual Postgres `pg_dump`, and CSV exports. The lesson: a `cp` on a hot directory is **not** a backup, and a filesystem snapshot of a running Postgres can be worse than nothing. You need to stop the service, dump the DBs, and tar a quiescent filesystem. That's what this does.

## How it works

1. **Phase 1** — If you declared Postgres DBs in `PG_DUMP_DBS`, dumps each one with `pg_dump -F c` into its `pgdata` directory. The dump rides into the tar for free.
2. **Phase 2** — Stops all running containers on the host.
3. **Phase 3** — Generates a `tar.gz` with multicore `pigz` of the paths listed in `PATHS_TO_BACKUP`. Default: `/DATA` + `/var/lib/casaos`.
4. **Phase 4** — Restarts the containers it stopped.
5. **Phase 5** — `rsync`s the tar to the NAS, then verifies remote size == local size.
6. **Phase 6** — Rotation: keeps the N most recent (default 3), deletes the rest.
7. **Phase 7** — Cleans the temporary `_predump_*.dump` files.
8. **Summary** — Sends a Telegram message with duration, size, and retained count.

If anything fails in any phase, the script:
- Restarts any containers it stopped (via `trap`).
- Cleans temporary files.
- Sends a Telegram message with the error.
- Exits non-zero so cron flags it as failed.

## Requirements

- A Raspberry Pi (or any Linux box) running CasaOS.
- Docker (the script stops/starts your containers).
- A NAS or external storage mounted on the host with write permissions.
- A Telegram bot token and chat ID.

## Installation

```bash
git clone https://github.com/soySantosPerez/Backup-CasaOS.git
cd Backup-CasaOS

# Install dependencies and set up .env
sudo ./install.sh

# Edit .env with your real values
nano .env

# Test it
sudo ./backup.sh
```

Or manually:

```bash
# Install dependencies (Debian/Ubuntu)
sudo apt-get install -y bash tar pigz rsync curl coreutils

# Set up config
cp .env.example .env
nano .env

chmod +x backup.sh
sudo ./backup.sh
```

## Setting up Telegram

1. In Telegram, find `@BotFather` and send `/newbot`. Follow the prompts. You'll get a **token**.
2. Open your new bot and send it any message (e.g. `/start`).
3. Get your `chat_id` by messaging `@userinfobot`, or by visiting:
   ```
   https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
   ```
   and finding `"chat":{"id":XXXXXXXX,...`
4. Test it works:
   ```bash
   curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/sendMessage" \
     -d "chat_id=<YOUR_CHAT_ID>" \
     -d "text=test"
   ```

## Running on multiple Pis

Clone the repo on each Pi and create a separate `.env` on each one with a unique `HOST_NAME`. Each Pi backs up to its own subfolder on the NAS (`$BACKUP_DEST/$HOST_NAME-backups/`), so they don't conflict.

## Schedule with cron

The installer can set this up for you, or do it manually:

```bash
sudo crontab -e
```

Add:

```cron
0 2 * * * cd /home/YOUR_USER/casaos-backup && ./backup.sh >> ./logs/cron.log 2>&1
```

## Restoring from a backup

```bash
# 1. Stop CasaOS and all its containers
sudo systemctl stop casaos
sudo docker stop $(docker ps -q)

# 2. Move old data aside for safety
sudo mv /DATA /DATA.old
sudo mv /var/lib/casaos /var/lib/casaos.old

# 3. Extract the backup
cd /
sudo tar -xzf /mnt/your-nas/my-pi-backups/my-pi_2026-05-15_020000.tar.gz

# 4. Restart CasaOS
sudo systemctl start casaos
```

## Configuration

| Variable | Required | Default | Description |
|---|---|---|---|
| `HOST_NAME` | yes | — | Host identifier (used in filenames and NAS subfolder) |
| `BACKUP_DEST` | yes | — | Path to NAS or external storage mount |
| `BACKUP_RETENTION` | no | `3` | Number of backups to keep per host |
| `PATHS_TO_BACKUP` | no | `/DATA,/var/lib/casaos` | Comma-separated paths to include |
| `PG_DUMP_DBS` | no | empty | DBs to dump: `container:user:database,...` |
| `TELEGRAM_BOT_TOKEN` | yes | — | Telegram bot token |
| `TELEGRAM_CHAT_ID` | yes | — | Chat ID for notifications |

## Troubleshooting

**Cron doesn't run**: cron on a Pi sometimes lacks a `PATH` that includes docker. Use `sudo crontab -e` (root's crontab) so Docker is accessible. Check `./logs/cron.log`.

**Telegram doesn't arrive**: test manually:
```bash
source .env
curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
  -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=test"
```

**NAS not mounted in time**: if cron runs before CIFS/NFS is ready, the script fails with "BACKUP_DEST does not exist". Make sure the mount is in `/etc/fstab` with `_netdev`, or mounted via systemd with `RequiresMountsFor`.

**Not enough temp space**: the tar is created in `/tmp` before being rsync'd. If your CasaOS data is huge, ensure `/tmp` has enough space or set `WORK_DIR` in the script.

## License

MIT. See [LICENSE](LICENSE).
