#!/bin/sh
# Runs inside the Navidrome image. Every start resets the database to the seed.
set -eu

if [ "${DEMO_BOOTSTRAP:-0}" = 1 ]; then
  : # bootstrap.sh prepared /data (empty, or a copy of the master seed)
else
  # Non-empty file with the SQLite header (15 chars + NUL); never start on anything else.
  if [ ! -s /seed/navidrome.db ] \
     || [ "$(head -c 15 /seed/navidrome.db)" != "SQLite format 3" ] \
     || [ "$(od -An -tx1 -j15 -N1 /seed/navidrome.db | tr -d ' ')" != "00" ]; then
    echo "demo: /seed/navidrome.db missing, empty or not a SQLite database; refusing to start (an empty DB lets the first visitor create the admin). Run bootstrap.sh." >&2
    exit 1
  fi
  cp /seed/navidrome.db /data/navidrome.db
  rm -f /data/navidrome.db-wal /data/navidrome.db-shm
fi
exec /app/navidrome
