#!/bin/sh
# Runs inside the Navidrome image. Every start resets the database to the seed.
set -eu

if [ -f /seed/navidrome.db ]; then
  cp /seed/navidrome.db /data/navidrome.db
  rm -f /data/navidrome.db-wal /data/navidrome.db-shm
elif [ "${DEMO_BOOTSTRAP:-0}" != 1 ]; then
  echo "demo: /seed/navidrome.db missing and DEMO_BOOTSTRAP!=1; refusing to start (an empty DB lets the first visitor create the admin). Run bootstrap.sh." >&2
  exit 1
fi
exec /app/navidrome
