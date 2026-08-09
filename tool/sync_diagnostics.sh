#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-clone}"
case "$MODE" in
  clone|primary-certification|throughput) ;;
  *)
    echo "Usage: $0 [clone|primary-certification|throughput]" >&2
    exit 64
    ;;
esac

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="${NAVIS_DIAGNOSTICS_PRIMARY_DB:-$HOME/Documents/navis.sqlite.sqlite}"
NORMAL_PRIMARY_DB="$HOME/Documents/navis.sqlite.sqlite"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/sync-diagnostics/$STAMP-$MODE"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
APP_LOG="$OUTPUT_ROOT/navis.log"
REPORT="$OUTPUT_ROOT/report.json"
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"

if [[ ! -f "$SOURCE_DB" ]]; then
  echo "Primary database not found: $SOURCE_DB" >&2
  exit 66
fi

if [[ "$MODE" == "primary-certification" ]]; then
  if [[ "$(readlink -f "$SOURCE_DB")" != "$(readlink -f "$NORMAL_PRIMARY_DB")" ]]; then
    echo "Primary certification must use the normal Navis database: $NORMAL_PRIMARY_DB" >&2
    exit 64
  fi
  if pgrep -f '/navis($| )|Navis' >/dev/null 2>&1; then
    echo "Refusing primary certification while another Navis process runs." >&2
    exit 75
  fi
  BACKUP_ROOT="${NAVIS_DIAGNOSTICS_BACKUP_ROOT:-$HOME/Documents/navis-certification-backups}"
  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"
  DATABASE_BACKUP="$BACKUP_ROOT/navis-$STAMP.sqlite"
  python3 - "$SOURCE_DB" "$DATABASE_BACKUP" <<'PY'
import sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
source.backup(target)
target.close()
source.close()
PY
  chmod 600 "$DATABASE_BACKUP"
  echo "$DATABASE_BACKUP" > "$OUTPUT_ROOT/backup-path.txt"
  DATABASE_DEFINE=()
else
  CLONE_DB="$OUTPUT_ROOT/navis-diagnostics.sqlite"
  python3 - "$SOURCE_DB" "$CLONE_DB" "$OUTPUT_ROOT/cache" <<'PY'
import os, shutil, sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
source.backup(target)
source.close()
cache_root = sys.argv[3]
os.makedirs(cache_root, exist_ok=True)
for song_id, source_path in target.execute(
    "SELECT song_id, file_path FROM cached_tracks"
).fetchall():
    extension = os.path.splitext(source_path)[1] or ".isolated"
    destination = os.path.join(cache_root, f"{song_id}{extension}")
    if os.path.isfile(source_path):
        shutil.copy2(source_path, destination)
    target.execute(
        "UPDATE cached_tracks SET file_path = ? WHERE song_id = ?",
        (destination, song_id),
    )
target.commit()
target.close()
PY
  chmod 600 "$CLONE_DB"
  DATABASE_DEFINE=(
    "--dart-define=NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT"
    "--dart-define=NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CLONE_DB"
  )
fi

write_database_summary() {
  local database_path="$1"
  local output_path="$2"
  local isolated_cache_root="${3:-}"
  python3 - "$database_path" "$output_path" "$isolated_cache_root" <<'PY'
import json, os, sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)

def count(sql, parameters=()):
    return db.execute(sql, parameters).fetchone()[0]

summary = {
    "integrity": [row[0] for row in db.execute("PRAGMA integrity_check")],
    "foreignKeys": [list(row) for row in db.execute("PRAGMA foreign_key_check")],
    "catalog": {
        "artists": count("SELECT COUNT(*) FROM artists"),
        "albums": count("SELECT COUNT(*) FROM albums"),
        "songs": count("SELECT COUNT(*) FROM songs"),
    },
    "liked": {
        "artists": count("SELECT COUNT(*) FROM artists WHERE starred IS NOT NULL"),
        "albums": count("SELECT COUNT(*) FROM albums WHERE starred IS NOT NULL"),
        "songs": count("SELECT COUNT(*) FROM songs WHERE starred IS NOT NULL"),
    },
    "playlists": {
        "headers": count("SELECT COUNT(*) FROM playlists"),
        "memberships": count("SELECT COUNT(*) FROM playlist_songs"),
    },
    "protectedMedia": {
        "cachedTracks": count("SELECT COUNT(*) FROM cached_tracks"),
        "permanentTracks": count(
            "SELECT COUNT(*) FROM cached_tracks WHERE cache_type = 'permanent'"
        ),
        "downloadQueue": count("SELECT COUNT(*) FROM download_queue"),
    },
    "aliases": count("SELECT COUNT(*) FROM song_identity_aliases"),
}
cache_root = sys.argv[3]
if cache_root:
    root = os.path.realpath(cache_root) + os.sep
    paths = [row[0] for row in db.execute("SELECT file_path FROM cached_tracks")]
    summary["cachePathsOutsideIsolatedRoot"] = sum(
        not os.path.realpath(path).startswith(root) for path in paths
    )
db.close()
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump(summary, output)
if summary["integrity"] != ["ok"] or summary["foreignKeys"]:
    raise SystemExit(1)
if summary.get("cachePathsOutsideIsolatedRoot", 0):
    raise SystemExit(1)
PY
}

BASELINE_DB="${DATABASE_BACKUP:-$CLONE_DB}"
write_database_summary \
  "$BASELINE_DB" \
  "$OUTPUT_ROOT/pre-run-database.json" \
  "${CLONE_DB:+$OUTPUT_ROOT/cache}"

cd "$PROJECT_DIR"
: > "$APP_LOG"
FLUTTER_PID=0

launch_app() {
  rm -f "$HANDSHAKE"
  local diagnostics_runtime_mode="$MODE"
  if [[ "$MODE" == "throughput" ]]; then
    diagnostics_runtime_mode="clone"
  fi
  flutter run -d linux --profile \
    --dart-define=NAVIS_UPDATE_CHANNEL=dev \
    --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
    --dart-define=NAVIS_APP_NAME='Navis Diagnostics' \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_MODE=$diagnostics_runtime_mode" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
    "${DATABASE_DEFINE[@]}" >>"$APP_LOG" 2>&1 &
  FLUTTER_PID=$!

  for _ in $(seq 1 180); do
    [[ -s "$HANDSHAKE" ]] && break
    if ! kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
      echo "Navis exited before diagnostics startup. See $APP_LOG" >&2
      exit 70
    fi
    sleep 1
  done
  if [[ ! -s "$HANDSHAKE" ]]; then
    echo "Timed out waiting for diagnostics API. See $APP_LOG" >&2
    exit 70
  fi

  read -r PORT TOKEN < <(
    python3 - "$HANDSHAKE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["port"], value["token"])
PY
  )
  BASE_URL="http://127.0.0.1:$PORT"
}

cleanup() {
  if (( FLUTTER_PID > 0 )) && kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
    kill "$FLUTTER_PID" >/dev/null 2>&1 || true
    wait "$FLUTTER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM
launch_app

api() {
  local method="$1"
  local route="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    curl --fail-with-body --silent --show-error \
      -X "$method" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' -d "$body" "$BASE_URL$route"
  else
    curl --fail-with-body --silent --show-error \
      -X "$method" -H "Authorization: Bearer $TOKEN" "$BASE_URL$route"
  fi
}

wait_for_sync() {
  local deadline=$((SECONDS + 14400))
  while (( SECONDS < deadline )); do
    local status
    status="$(api GET /v1/sync/status)"
    if python3 - "$status" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
done = (
    not value.get("requestActive", False)
    and value.get("status") not in ("running", "idle")
)
raise SystemExit(0 if done else 1)
PY
    then
      printf '%s\n' "$status"
      return
    fi
    sleep 2
  done
  echo "Timed out waiting for sync." >&2
  exit 70
}

wait_for_candidate_collection() {
  local deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    local status
    status="$(api GET /v1/sync/status)"
    if python3 - "$status" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
terminal = (
    not value.get("requestActive", False)
    and value.get("status") in ("failed", "cancelled", "deferred", "skipped")
)
raise SystemExit(0 if terminal else 1)
PY
    then
      echo "Catalog candidate did not begin collection: $status" >&2
      exit 70
    fi
    if python3 - "$status" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
ready = (
    value.get("requestActive", False)
    and value.get("candidateStatus") in ("collecting", "ready", "applying")
)
raise SystemExit(0 if ready else 1)
PY
    then
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for candidate collection." >&2
  exit 70
}

wait_for_candidate_rows() {
  local deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    local status generation
    status="$(api GET /v1/sync/status)"
    generation="$(python3 - "$status" <<'PY'
import json, sys
print(json.loads(sys.argv[1]).get("candidateGeneration") or "")
PY
)"
    if [[ -n "$generation" ]] && python3 - "$CLONE_DB" "$generation" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
generation = int(sys.argv[2])
count = sum(db.execute(
    f"SELECT COUNT(*) FROM {table} WHERE generation = ?", (generation,)
).fetchone()[0] for table in (
    "library_sync_candidate_artists",
    "library_sync_candidate_albums",
    "library_sync_candidate_songs",
))
db.close()
raise SystemExit(0 if count > 0 else 1)
PY
    then
      printf '%s\n' "$generation"
      return
    fi
    sleep 1
  done
  echo "Timed out waiting for a durable candidate checkpoint." >&2
  exit 70
}

HEALTH="$(api GET /v1/health)"
printf '%s\n' "$HEALTH" > "$OUTPUT_ROOT/health.json"
IFS=$'\t' read -r SONG_ID ORIGINAL_STARRED < <(python3 - "$SOURCE_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = db.execute(
    "SELECT id, starred IS NOT NULL FROM songs "
    "WHERE is_provisional = 0 AND server_deleted_at IS NULL "
    "AND suffix = 'mp3' "
    "AND NOT EXISTS ("
    "SELECT 1 FROM cached_tracks WHERE cached_tracks.song_id = songs.id"
    ") ORDER BY COALESCE(duration, 0) DESC LIMIT 1"
).fetchone()
db.close()
print(f"{row[0]}\t{row[1]}" if row else "\t0")
PY
)
if [[ -n "$SONG_ID" && "$MODE" != "throughput" ]]; then
  api POST /v1/playback/start "$(python3 - "$SONG_ID" <<'PY'
import json, sys
print(json.dumps({"songId": sys.argv[1]}))
PY
)" > "$OUTPUT_ROOT/playback-start.json"
fi

if [[ "$MODE" == "throughput" ]]; then
  api POST /v1/diagnostics/overrides \
    '{"networkType":"wifi","nativeMetered":false,"backgroundSyncUnmeteredOnly":true,"requestReporting":true}' \
    > "$OUTPUT_ROOT/throughput-overrides.json"
  api POST /v1/search/source-audit '{"query":"","songCount":1000,"songOffset":0}' \
    | jq '{query, songCount, songOffset, resultCounts}' \
    > "$OUTPUT_ROOT/throughput-search-page-0.json"
  api POST /v1/search/source-audit '{"query":"","songCount":1000,"songOffset":1000}' \
    | jq '{query, songCount, songOffset, resultCounts}' \
    > "$OUTPUT_ROOT/throughput-search-page-1000.json"
  api POST /v1/sync/repair > "$OUTPUT_ROOT/throughput-repair-start.json"
  for _ in $(seq 1 600); do
    STATUS="$(api GET /v1/sync/status)"
    if python3 - "$STATUS" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
# A full repair reports the broad catalog stage while its candidate hydration
# is active, so stage alone is not a reliable readiness signal. Either the
# paginated song fast path or the album fallback proves that hydration started.
requests = value.get("endpointRequests") or {}
ready = value.get("candidateGeneration") and (
    requests.get("getAlbum", 0) > 0 or requests.get("searchSongsPage", 0) >= 2
)
raise SystemExit(0 if ready else 1)
PY
    then
      break
    fi
    sleep 1
  done
  printf '%s\n' "$STATUS" > "$OUTPUT_ROOT/throughput-before.json"
  GENERATION="$(python3 - "$OUTPUT_ROOT/throughput-before.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("candidateGeneration") or "")
PY
)"
  if [[ -z "$GENERATION" ]]; then
    echo "Repair did not reach candidate song hydration." >&2
    exit 70
  fi
  BEFORE_HYDRATED="$(sqlite3 "$CLONE_DB" "SELECT COUNT(*) FROM library_sync_candidate_albums WHERE generation = $GENERATION AND songs_hydrated = 1;")"
  BEFORE_SONGS="$(sqlite3 "$CLONE_DB" "SELECT COUNT(*) FROM library_sync_candidate_songs WHERE generation = $GENERATION;")"
  sleep 15
  api GET /v1/sync/status > "$OUTPUT_ROOT/throughput-after.json"
  AFTER_HYDRATED="$(sqlite3 "$CLONE_DB" "SELECT COUNT(*) FROM library_sync_candidate_albums WHERE generation = $GENERATION AND songs_hydrated = 1;")"
  AFTER_SONGS="$(sqlite3 "$CLONE_DB" "SELECT COUNT(*) FROM library_sync_candidate_songs WHERE generation = $GENERATION;")"
  python3 - "$OUTPUT_ROOT/throughput-before.json" "$OUTPUT_ROOT/throughput-after.json" "$BEFORE_HYDRATED" "$AFTER_HYDRATED" "$BEFORE_SONGS" "$AFTER_SONGS" "$OUTPUT_ROOT/throughput.json" <<'PY'
import json, sys
before = json.load(open(sys.argv[1], encoding="utf-8"))
after = json.load(open(sys.argv[2], encoding="utf-8"))
result = {
    "intervalSeconds": 15,
    "candidateGeneration": before.get("candidateGeneration"),
    "hydratedAlbumsBefore": int(sys.argv[3]),
    "hydratedAlbumsAfter": int(sys.argv[4]),
    "hydratedAlbumsPerSecond": (int(sys.argv[4]) - int(sys.argv[3])) / 15,
    "candidateSongsBefore": int(sys.argv[5]),
    "candidateSongsAfter": int(sys.argv[6]),
    "candidateSongsPerSecond": (int(sys.argv[6]) - int(sys.argv[5])) / 15,
    "endpointRequests": after.get("endpointRequests"),
}
with open(sys.argv[7], "w", encoding="utf-8") as output:
    json.dump(result, output)
print(json.dumps(result, indent=2))
PY
  api POST /v1/sync/cancel > "$OUTPUT_ROOT/throughput-cancel.json"
  for _ in $(seq 1 30); do
    STATUS="$(api GET /v1/sync/status)"
    if python3 - "$STATUS" <<'PY'
import json, sys
raise SystemExit(0 if not json.loads(sys.argv[1]).get("requestActive") else 1)
PY
    then
      break
    fi
    sleep 1
  done
  api POST /v1/shutdown > "$OUTPUT_ROOT/throughput-shutdown.json" || true
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
  echo "Throughput diagnostics completed: $OUTPUT_ROOT"
  exit 0
elif [[ "$MODE" == "clone" ]]; then
  api POST /v1/diagnostics/overrides \
    '{"networkType":"cellular","backgroundSyncUnmeteredOnly":true,"requestReporting":true}' \
    > "$OUTPUT_ROOT/guardrails-overrides-cellular.json"

  api POST /v1/sync/automatic > "$OUTPUT_ROOT/guardrails-cellular-automatic-start.json"
  wait_for_sync > "$OUTPUT_ROOT/guardrails-cellular-automatic-result.json"
  python3 - "$OUTPUT_ROOT/guardrails-cellular-automatic-result.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
endpoints = value.get("endpointRequests") or {}
assert endpoints.get("getIndexes", 0) <= 1, endpoints
assert value.get("planKind") in (None, "probe", "targetedHydration"), value
PY

  api POST /v1/diagnostics/overrides \
    '{"networkType":"wifi","nativeMetered":true,"backgroundSyncUnmeteredOnly":true,"requestReporting":true}' \
    > "$OUTPUT_ROOT/guardrails-overrides-metered-wifi.json"
  api POST /v1/sync/automatic > "$OUTPUT_ROOT/guardrails-metered-wifi-start.json"
  wait_for_sync > "$OUTPUT_ROOT/guardrails-metered-wifi-result.json"
  python3 - "$OUTPUT_ROOT/guardrails-metered-wifi-result.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
endpoints = value.get("endpointRequests") or {}
assert endpoints.get("getIndexes", 0) <= 1, endpoints
PY

  ALBUM_ID="$(python3 - "$CLONE_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = db.execute(
    "SELECT id FROM albums WHERE songs_hydrated = 0 LIMIT 1"
).fetchone()
db.close()
print(row[0] if row else "")
PY
)"
  if [[ -n "$ALBUM_ID" ]]; then
    api POST /v1/diagnostics/overrides \
      '{"networkType":"cellular","interactiveHydrationAllowed":true,"requestReporting":true}' \
      > "$OUTPUT_ROOT/guardrails-interactive-overrides.json"
    api POST /v1/sync/target \
      "$(python3 - "$ALBUM_ID" <<'PY'
import json, sys
print(json.dumps({"targetKind": "album", "entityId": sys.argv[1]}))
PY
)" > "$OUTPUT_ROOT/guardrails-interactive-start.json"
    wait_for_sync > "$OUTPUT_ROOT/guardrails-interactive-result.json"
    python3 - "$OUTPUT_ROOT/guardrails-interactive-result.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
endpoints = value.get("endpointRequests") or {}
assert value.get("allowsInteractiveHydration") is True, value
assert endpoints.get("getAlbum", 0) >= 1 or value.get("status") == "deferred", value
PY
  fi

  api POST /v1/diagnostics/overrides \
    '{"networkType":"cellular","backgroundSyncUnmeteredOnly":true,"requestReporting":true}' \
    > "$OUTPUT_ROOT/guardrails-no-override-overrides.json"
  api POST /v1/sync/repair '{}' > "$OUTPUT_ROOT/guardrails-no-override-repair-start.json"
  wait_for_sync > "$OUTPUT_ROOT/guardrails-no-override-repair-result.json"
  python3 - "$OUTPUT_ROOT/guardrails-no-override-repair-result.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value.get("status") in ("deferred", "skipped", "succeeded", "partial"), value
endpoints = value.get("endpointRequests") or {}
if value.get("status") == "deferred":
    assert value.get("updatesAvailable") is True, value
assert endpoints.get("getIndexes", 0) <= 1, endpoints
PY

  api POST /v1/sync/repair '{"allowMeteredBroadOverride":true}' \
    > "$OUTPUT_ROOT/guardrails-override-repair-start.json"
  wait_for_sync > "$OUTPUT_ROOT/guardrails-override-repair-result.json"
  python3 - "$OUTPUT_ROOT/guardrails-override-repair-result.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value.get("status") != "deferred" or value.get("planReason") != "networkPolicyDeferred", value
PY

  api POST /v1/diagnostics/overrides '{}' \
    > "$OUTPUT_ROOT/guardrails-reset-overrides.json"

  api POST /v1/sync/repair > "$OUTPUT_ROOT/cancelled-repair-start.json"
  sleep 2
  api POST /v1/sync/cancel > "$OUTPUT_ROOT/cancel.json"
  wait_for_sync > "$OUTPUT_ROOT/cancelled-repair-result.json"

  api POST /v1/sync/repair > "$OUTPUT_ROOT/interrupted-repair-start.json"
  wait_for_candidate_collection
  INTERRUPTED_GENERATION="$(wait_for_candidate_rows)"
  api GET /v1/sync/status > "$OUTPUT_ROOT/interruption-status.json"
  kill "$FLUTTER_PID"
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
  python3 - "$CLONE_DB" "$INTERRUPTED_GENERATION" \
    "$OUTPUT_ROOT/interruption-checkpoint.json" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
generation = int(sys.argv[2])
counts = {
    name: db.execute(
        f"SELECT COUNT(*) FROM {table} WHERE generation = ?", (generation,)
    ).fetchone()[0]
    for name, table in (
        ("artists", "library_sync_candidate_artists"),
        ("albums", "library_sync_candidate_albums"),
        ("songs", "library_sync_candidate_songs"),
    )
}
db.close()
with open(sys.argv[3], "w", encoding="utf-8") as output:
    json.dump({"generation": generation, "candidateRows": counts}, output)
assert sum(counts.values()) > 0, counts
PY

  launch_app
  api GET /v1/health > "$OUTPUT_ROOT/restart-health.json"
  if [[ -n "$SONG_ID" ]]; then
    api POST /v1/playback/start "$(python3 - "$SONG_ID" <<'PY'
import json, sys
print(json.dumps({"songId": sys.argv[1]}))
PY
)" > "$OUTPUT_ROOT/restart-playback-start.json"
  fi
  sleep 2
  RESTART_STATUS="$(api GET /v1/sync/status)"
  if python3 - "$RESTART_STATUS" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
busy = value.get("requestActive") or value.get("status") == "running"
raise SystemExit(0 if busy else 1)
PY
  then
    wait_for_sync > "$OUTPUT_ROOT/startup-resume-result.json"
  else
    printf '%s\n' "$RESTART_STATUS" > "$OUTPUT_ROOT/startup-resume-result.json"
  fi
  api POST /v1/sync/repair > "$OUTPUT_ROOT/repair-resume-start.json"
  wait_for_sync > "$OUTPUT_ROOT/repair-result.json"
  api POST /v1/sync/repair > "$OUTPUT_ROOT/identical-repair-start.json"
  if [[ -n "$SONG_ID" ]]; then
    wait_for_candidate_collection
    api POST /v1/diagnostics/local-mutation \
      "$(python3 - "$SONG_ID" <<'PY'
import json, sys
print(json.dumps({"type":"song","id":sys.argv[1],"field":"starred","value":True}))
PY
)" > "$OUTPUT_ROOT/local-mutation.json"
  fi
  wait_for_sync > "$OUTPUT_ROOT/identical-repair-result.json"
  if [[ -n "$SONG_ID" ]]; then
    python3 - "$CLONE_DB" "$SONG_ID" "$OUTPUT_ROOT/local-mutation-validation.json" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = db.execute(
    "SELECT starred IS NOT NULL FROM songs WHERE id = ?", (sys.argv[2],)
).fetchone()
db.close()
with open(sys.argv[3], "w", encoding="utf-8") as output:
    json.dump({"songId": sys.argv[2], "starred": row[0] if row else None}, output)
assert row == (1,), {"mutationSong": sys.argv[2], "starred": row}
PY
    api POST /v1/diagnostics/restore-server-star \
      "$(python3 - "$SONG_ID" "$ORIGINAL_STARRED" <<'PY'
import json, sys
print(json.dumps({"songId": sys.argv[1], "liked": sys.argv[2] == "1"}))
PY
)" > "$OUTPUT_ROOT/server-star-restoration.json"
  fi
  for ZERO_WRITE_ATTEMPT in 1 2 3; do
    api POST /v1/sync/repair \
      > "$OUTPUT_ROOT/zero-write-repair-$ZERO_WRITE_ATTEMPT-start.json"
    wait_for_sync \
      > "$OUTPUT_ROOT/zero-write-repair-$ZERO_WRITE_ATTEMPT-result.json"
    api GET /v1/diagnostics/report \
      > "$OUTPUT_ROOT/zero-write-repair-$ZERO_WRITE_ATTEMPT-report.json"
    if python3 - "$OUTPUT_ROOT/zero-write-repair-$ZERO_WRITE_ATTEMPT-report.json" <<'PY'
import json, sys
promotion = json.load(open(sys.argv[1], encoding="utf-8")).get("promotion") or {}
raise SystemExit(0 if promotion.get("changed") == 0 else 1)
PY
    then
      break
    fi
  done
else
  api POST /v1/sync/repair > "$OUTPUT_ROOT/repair-start.json"
  wait_for_sync > "$OUTPUT_ROOT/repair-result.json"
  PRIMARY_REPAIR_STATUS="$(cat "$OUTPUT_ROOT/repair-result.json")"
  if python3 - "$PRIMARY_REPAIR_STATUS" <<'PY'
import json, sys
raise SystemExit(0 if json.loads(sys.argv[1]).get("candidateStatus") else 1)
PY
  then
    api POST /v1/sync/repair > "$OUTPUT_ROOT/repair-confirmation-start.json"
    wait_for_sync > "$OUTPUT_ROOT/repair-confirmation-result.json"
  fi
fi

api POST /v1/sync/check > "$OUTPUT_ROOT/check-start.json"
wait_for_sync > "$OUTPUT_ROOT/check-result.json"
api GET /v1/diagnostics/report > "$REPORT"
api POST /v1/shutdown > "$OUTPUT_ROOT/shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0
if [[ "$MODE" == "primary-certification" ]]; then
  launch_app
  api GET /v1/health > "$OUTPUT_ROOT/restart-health.json"
  api GET /v1/sync/status > "$OUTPUT_ROOT/restart-sync-status.json"
  api POST /v1/shutdown > "$OUTPUT_ROOT/restart-shutdown.json" || true
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
fi
trap - EXIT INT TERM

VALIDATED_DB="${CLONE_DB:-$SOURCE_DB}"
write_database_summary \
  "$VALIDATED_DB" \
  "$OUTPUT_ROOT/database-validation.json" \
  "${CLONE_DB:+$OUTPUT_ROOT/cache}"

python3 - "$OUTPUT_ROOT/pre-run-database.json" \
  "$OUTPUT_ROOT/database-validation.json" <<'PY'
import json, sys
before = json.load(open(sys.argv[1], encoding="utf-8"))
after = json.load(open(sys.argv[2], encoding="utf-8"))
for key in ("permanentTracks",):
    assert after["protectedMedia"][key] >= before["protectedMedia"][key], (key, before, after)
assert after["aliases"] >= before["aliases"], (before, after)
PY

python3 - "$REPORT" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
promotion = report.get("promotion") or {}
frames = report.get("frames") or {}
canary = report.get("databaseCanary") or {}
playback = report.get("playback") or {}
assert promotion.get("applyDurationMs", 5001) <= 5000, promotion
assert promotion.get("unchanged", 0) > 0, promotion
if report.get("mode") == "clone":
    assert promotion.get("changed", 1) == 0, promotion
assert promotion.get("maximumPageSize", 501) <= 500, promotion
assert promotion.get("rssGrowthBytes", 64 * 1024 * 1024 + 1) <= 64 * 1024 * 1024, promotion
assert frames.get("p99Micros", 32001) <= 32000, frames
assert frames.get("maxMicros", 100001) <= 100000, frames
assert canary.get("p95Micros", 100001) <= 100000, canary
assert canary.get("maxMicros", 500001) <= 500000, canary
assert playback.get("loadFailures", 1) == 0, playback
assert playback.get("active") is True, playback
assert playback.get("playing") is True, playback
PY

echo "Diagnostics completed: $OUTPUT_ROOT"
if [[ "$MODE" == "primary-certification" ]]; then
  echo "Retained recovery backup: $DATABASE_BACKUP"
fi
