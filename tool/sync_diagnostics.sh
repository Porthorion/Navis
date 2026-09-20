#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-clone}"
case "$MODE" in
  clone|primary-certification|throughput|full-rescan|cache-alias) ;;
  *)
    echo "Usage: $0 [clone|primary-certification|throughput|full-rescan|cache-alias]" >&2
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
  python3 - "$SOURCE_DB" "$CLONE_DB" "$OUTPUT_ROOT/cache" \
    "${NAVIS_DIAGNOSTICS_USERNAME:-}" "$MODE" <<'PY'
import json, os, shutil, sqlite3, sys, time
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
username = sys.argv[4].strip()
if username:
    target.execute("UPDATE server_config SET username = ?", (username,))
if sys.argv[5] in ("cache-alias", "full-rescan"):
    # Diagnostics run against a disposable clone. Start the selected scenario
    # without a stale candidate or queued broad repair resuming ahead of it.
    for table in (
        "library_sync_work",
        "library_sync_candidate_artists",
        "library_sync_candidate_albums",
        "library_sync_candidate_songs",
    ):
        target.execute(f"DELETE FROM {table}")
    now = int(time.time())
    target.execute(
        "UPDATE server_config SET last_synced = ?, last_full_synced = ?",
        (now, now),
    )
    target.execute('''
        UPDATE library_sync_state
        SET last_checked_at = ?, last_catalog_synced_at = ?,
            last_auxiliary_synced_at = ?, last_genres_synced_at = ?,
            last_audit_at = ?, audit_offset = 0,
            candidate_generation = NULL, candidate_status = NULL,
            candidate_started_at = NULL, candidate_carried_forward_count = 0
    ''', (now, now, now, now, now))
    row = target.execute(
        "SELECT id, capabilities FROM server_config ORDER BY id LIMIT 1"
    ).fetchone()
    if row is not None:
        server_id, capabilities = row
        try:
            parsed = json.loads(capabilities) if capabilities else {}
        except (TypeError, json.JSONDecodeError):
            parsed = {}
        navis = parsed.get("navis")
        if not isinstance(navis, dict):
            navis = {}
            parsed["navis"] = navis
        for key in (
            "libraryPendingIndexesFingerprint",
            "libraryPendingIndexesCursor",
            "libraryPendingIndexesOffset",
            "libraryPendingIndexesArtistIds",
            "librarySyncFailureDiagnostics",
            "librarySyncFailureRecordedAt",
        ):
            navis.pop(key, None)
        navis["libraryFreshness"] = "current"
        navis["libraryHealthCheckedAt"] = time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)
        )
        target.execute(
            "UPDATE server_config SET capabilities = ? WHERE id = ?",
            (json.dumps(parsed, separators=(",", ":")), server_id),
        )
target.commit()
target.close()
PY
  chmod 600 "$CLONE_DB"
  DATABASE_DEFINE=(
    "--dart-define=NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT"
    "--dart-define=NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CLONE_DB"
  )
  if [[ -n "${NAVIS_DIAGNOSTICS_CREDENTIAL_PATH:-}" ]]; then
    if [[ ! -f "$NAVIS_DIAGNOSTICS_CREDENTIAL_PATH" ]]; then
      echo "Diagnostics credential file was not found." >&2
      exit 66
    fi
    DATABASE_DEFINE+=(
      "--dart-define=NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=$NAVIS_DIAGNOSTICS_CREDENTIAL_PATH"
    )
  fi
  if [[ -n "${NAVIS_DIAGNOSTICS_LASTFM_KEY_FILE:-}" ]]; then
    if [[ ! -f "$NAVIS_DIAGNOSTICS_LASTFM_KEY_FILE" || -L "$NAVIS_DIAGNOSTICS_LASTFM_KEY_FILE" ]]; then
      echo "Last.fm diagnostics key file must be a regular file." >&2
      exit 66
    fi
    if [[ "$(stat -c '%u' "$NAVIS_DIAGNOSTICS_LASTFM_KEY_FILE")" != "$(id -u)" ||
          "$(stat -c '%a' "$NAVIS_DIAGNOSTICS_LASTFM_KEY_FILE")" != "600" ]]; then
      echo "Last.fm diagnostics key file must be owned by this user with mode 600." >&2
      exit 77
    fi
    DATABASE_DEFINE+=(
      "--dart-define=NAVIS_SYNC_DIAGNOSTICS_LASTFM_KEY_FILE=$NAVIS_DIAGNOSTICS_LASTFM_KEY_FILE"
    )
  fi
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
  local diagnostics_data_home=""
  local -a diagnostics_environment=()
  if [[ "$MODE" != "primary-certification" ]]; then
    diagnostics_data_home="$OUTPUT_ROOT/app-data"
    diagnostics_environment+=("XDG_DATA_HOME=$diagnostics_data_home")
    local changelog_version
    changelog_version="$(awk '/^version:/ {split($2, parts, "+"); print parts[1]; exit}' "$PROJECT_DIR/pubspec.yaml")"
    mkdir -p "$diagnostics_data_home/com.navis.app.navis"
    # A first-run changelog dialog would mask the actual repair progress. Keep
    # clone-only app-support state isolated and mark this build as already seen.
    printf '%s\n' "$changelog_version" \
      > "$diagnostics_data_home/com.navis.app.navis/changelog_seen_version.txt"
  fi
  if [[ "$MODE" == "throughput" || "$MODE" == "full-rescan" || "$MODE" == "cache-alias" ]]; then
    diagnostics_runtime_mode="clone"
  fi
  env "${diagnostics_environment[@]}" flutter run -d linux --profile \
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
      if python3 - "$status" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
raise SystemExit(0 if value.get("planReason") == "leaseHeld" else 1)
PY
      then
        return 75
      fi
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

if [[ "$MODE" == "cache-alias" ]]; then
  # This intentionally creates the provisional row only in the isolated
  # profile. The server supplies the canonical album response; the assertion
  # below proves production hydration transfers cache ownership to that ID.
  CACHE_ALIAS_ALBUM_ID="$(python3 - "$CLONE_DB" "$OUTPUT_ROOT/cache" \
    "${NAVIS_DIAGNOSTICS_CACHE_ALIAS_OFFSET:-0}" <<'PY'
import os, sqlite3, sys, time
db = sqlite3.connect(sys.argv[1])
cache_root = sys.argv[2]
offset = max(0, int(sys.argv[3]))
row = db.execute('''
  WITH unique_recordings AS (
    SELECT recording_mbid
    FROM songs
    WHERE recording_mbid IS NOT NULL
      AND TRIM(recording_mbid) != ''
      AND is_provisional = 0
    GROUP BY recording_mbid
    HAVING COUNT(*) = 1
  )
  SELECT s.title, s.album_id, s.artist_id, s.artist_name, s.album_name,
         s.track, s.disc_number, s.duration, s.recording_mbid
  FROM songs s
  JOIN albums a ON a.id = s.album_id
  JOIN unique_recordings unique_mbid ON unique_mbid.recording_mbid = s.recording_mbid
  WHERE s.recording_mbid IS NOT NULL
    AND TRIM(s.recording_mbid) != ''
    AND a.songs_hydrated = 1
  ORDER BY COALESCE(a.server_created_at, 0) DESC
  LIMIT 1 OFFSET ?
''', (offset,)).fetchone()
if row is None:
    raise SystemExit('No uniquely identifiable hydrated song is available.')
title, album_id, artist_id, artist_name, album_name, track, disc, duration, mbid = row
remote_id = 'navis-diagnostics-provisional-cache-alias'
remote_album_id = 'navis-diagnostics-provisional-cache-alias-album'
remote_artist_id = 'navis-diagnostics-provisional-cache-alias-artist'
path = os.path.join(cache_root, remote_id + '.cache')
with open(path, 'wb') as output:
    output.write(b'isolated cache identity migration probe')
db.execute('DELETE FROM cached_tracks WHERE song_id = ?', (remote_id,))
db.execute('DELETE FROM songs WHERE id = ?', (remote_id,))
db.execute('DELETE FROM song_identity_aliases WHERE old_song_id = ?', (remote_id,))
db.execute('DELETE FROM albums WHERE id = ?', (remote_album_id,))
db.execute('DELETE FROM artists WHERE id = ?', (remote_artist_id,))
db.execute('''
  INSERT INTO artists (id, name, is_provisional, is_external)
  VALUES (?, ?, 1, 1)
''', (remote_artist_id, artist_name))
db.execute('''
  INSERT INTO albums (
    id, name, artist_id, artist_name, is_provisional, is_external
  ) VALUES (?, ?, ?, ?, 1, 1)
''', (remote_album_id, album_name, remote_artist_id, artist_name))
db.execute('''
  INSERT INTO songs (
    id, title, album_id, artist_id, artist_name, album_name, track,
    disc_number, duration, recording_mbid, is_provisional, is_external
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1)
''', (remote_id, title, remote_album_id, remote_artist_id, artist_name, album_name,
      track, disc, duration, mbid))
db.execute('''
  INSERT INTO cached_tracks (
    song_id, file_path, file_size, format, last_accessed_at, cache_type,
    download_status
  ) VALUES (?, ?, ?, 'cache', ?, 'rolling', 'complete')
''', (remote_id, path, os.path.getsize(path), int(time.time())))
db.commit()
db.close()
print(album_id)
PY
)"
  api POST /v1/diagnostics/overrides \
    '{"networkType":"wifi","nativeMetered":false,"interactiveHydrationAllowed":true,"requestReporting":true}' \
    > "$OUTPUT_ROOT/cache-alias-overrides.json"
  api POST /v1/sync/target "$(python3 - "$CACHE_ALIAS_ALBUM_ID" <<'PY'
import json, sys
print(json.dumps({'targetKind': 'album', 'entityId': sys.argv[1]}))
PY
)" > "$OUTPUT_ROOT/cache-alias-start.json"
  wait_for_sync > "$OUTPUT_ROOT/cache-alias-result.json"
  api POST /v1/shutdown > "$OUTPUT_ROOT/shutdown.json" || true
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
  trap - EXIT INT TERM
  python3 - "$CLONE_DB" "$OUTPUT_ROOT/cache-alias-result.json" \
    "$OUTPUT_ROOT/cache-alias-validation.json" <<'PY'
import json, os, sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
result = json.load(open(sys.argv[2], encoding='utf-8'))
remote_id = 'navis-diagnostics-provisional-cache-alias'
alias = db.execute(
    'SELECT canonical_song_id FROM song_identity_aliases WHERE old_song_id = ?',
    (remote_id,),
).fetchone()
remote_cache_count = db.execute(
    'SELECT COUNT(*) FROM cached_tracks WHERE song_id = ?', (remote_id,)
).fetchone()[0]
canonical_cache = None
if alias is not None:
    canonical_cache = db.execute(
        'SELECT file_path FROM cached_tracks WHERE song_id = ?', (alias[0],)
    ).fetchone()
value = {
    'syncStatus': result.get('status'),
    'planKind': result.get('planKind'),
    'requests': result.get('requests'),
    'aliasCreated': alias is not None,
    'remoteCacheRows': remote_cache_count,
    'canonicalCacheRows': 1 if canonical_cache is not None else 0,
    'cacheFilePresent': bool(canonical_cache and os.path.isfile(canonical_cache[0])),
}
with open(sys.argv[3], 'w', encoding='utf-8') as output:
    json.dump(value, output)
db.close()
assert value['syncStatus'] in ('succeeded', 'partial'), value
assert value['aliasCreated'], value
assert value['remoteCacheRows'] == 0, value
assert value['canonicalCacheRows'] == 1, value
assert value['cacheFilePresent'], value
PY
  echo "Cache-alias diagnostics completed: $OUTPUT_ROOT"
  exit 0
fi

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
if [[ -n "$SONG_ID" && "$MODE" != "throughput" && "$MODE" != "full-rescan" ]]; then
  api POST /v1/playback/start "$(python3 - "$SONG_ID" <<'PY'
import json, sys
print(json.dumps({"songId": sys.argv[1]}))
PY
)" > "$OUTPUT_ROOT/playback-start.json"
fi

if [[ "$MODE" == "full-rescan" ]]; then
  api POST /v1/diagnostics/overrides \
    '{"networkType":"wifi","nativeMetered":false,"backgroundSyncUnmeteredOnly":true,"requestReporting":true}' \
    > "$OUTPUT_ROOT/full-rescan-overrides.json"
  api POST /v1/sync/repair > "$OUTPUT_ROOT/full-rescan-start.json"
  # The repair request publishes its preparing state before durable planning
  # begins. Capture that real Flutter frame so this diagnostic guards against
  # the old idle/blank gap after the keyboard shortcut is pressed.
  api POST /v1/presentation/screenshot '{"label":"full-rescan-preparing"}' \
    > "$OUTPUT_ROOT/full-rescan-preparing-screenshot.json"
  python3 - "$OUTPUT_ROOT/full-rescan-preparing-screenshot.json" "$OUTPUT_ROOT" \
    "$OUTPUT_ROOT/full-rescan-preparing-screenshot-path.txt" <<'PY'
import json, os, sys
metadata_path, root, output_path = sys.argv[1:]
value = json.load(open(metadata_path, encoding="utf-8"))
artifact = value.get("artifact")
if not isinstance(artifact, str) or os.path.isabs(artifact):
    raise SystemExit("full-rescan screenshot artifact must be relative")
root = os.path.realpath(root)
path = os.path.realpath(os.path.join(root, artifact))
if os.path.commonpath([root, path]) != root:
    raise SystemExit("full-rescan screenshot escaped diagnostics root")
with open(path, "rb") as screenshot:
    if screenshot.read(8) != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("full-rescan screenshot is not a PNG")
with open(output_path, "w", encoding="utf-8") as output:
    output.write(path + "\n")
PY
  FULL_RESCAN_TRACE="$OUTPUT_ROOT/full-rescan-progress.jsonl"
  FULL_RESCAN_STARTED_AT="$(date +%s)"
  FULL_RESCAN_DEADLINE=$((SECONDS + 14400))
  FULL_RESCAN_CONFIRMATION_ATTEMPTED=0
  while (( SECONDS < FULL_RESCAN_DEADLINE )); do
    STATUS="$(api GET /v1/sync/status)"
    python3 - "$STATUS" "$FULL_RESCAN_STARTED_AT" >> "$FULL_RESCAN_TRACE" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
record = {
    'elapsedSeconds': int(__import__('time').time()) - int(sys.argv[2]),
    'requestActive': value.get('requestActive'),
    'status': value.get('status'),
    'stage': value.get('stage'),
    'candidateStatus': value.get('candidateStatus'),
    'processed': value.get('processed'),
    'total': value.get('total'),
    'hydrationAlbumsPerSecond': value.get('hydrationAlbumsPerSecond'),
    'requests': value.get('requests'),
    'endpointRequests': value.get('endpointRequests'),
}
print(json.dumps(record, separators=(',', ':')))
PY
    if python3 - "$STATUS" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
done = not value.get('requestActive', False) and value.get('status') not in ('running', 'idle')
raise SystemExit(0 if done else 1)
PY
    then
      if [[ "$FULL_RESCAN_CONFIRMATION_ATTEMPTED" == "0" ]] && \
        python3 - "$STATUS" <<'PY'
import json, sys
raise SystemExit(0 if json.loads(sys.argv[1]).get('candidateStatus') else 1)
PY
      then
        FULL_RESCAN_CONFIRMATION_ATTEMPTED=1
        api POST /v1/sync/repair > "$OUTPUT_ROOT/full-rescan-confirmation-start.json"
        continue
      fi
      printf '%s\n' "$STATUS" > "$OUTPUT_ROOT/full-rescan-result.json"
      break
    fi
    sleep 1
  done
  if [[ ! -s "$OUTPUT_ROOT/full-rescan-result.json" ]]; then
    echo "Timed out waiting for the full rescan." >&2
    exit 70
  fi
  api GET /v1/diagnostics/report > "$OUTPUT_ROOT/full-rescan-report.json"
  api POST /v1/shutdown > "$OUTPUT_ROOT/full-rescan-shutdown.json" || true
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
  echo "Full-rescan diagnostics completed: $OUTPUT_ROOT"
  exit 0
elif [[ "$MODE" == "throughput" ]]; then
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

  # A foreground user request is deliberately more useful than automatic
  # cellular work, but still must not turn into a catalog/artist/song sweep.
  api POST /v1/sync/check '{}' \
    > "$OUTPUT_ROOT/guardrails-cellular-manual-check-start.json"
  wait_for_sync > "$OUTPUT_ROOT/guardrails-cellular-manual-check-result.json"
  python3 - "$OUTPUT_ROOT/guardrails-cellular-manual-check-result.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
endpoints = value.get("endpointRequests") or {}
assert value.get("planKind") == "deltaReconcile", value
assert value.get("planReason") == "manualMeteredLimitedDiscovery", value
assert endpoints.get("getNewestAlbumList2", 0) == 1, endpoints
assert endpoints.get("getArtist", 0) == 0, endpoints
assert endpoints.get("searchSongsPage", 0) == 0, endpoints
assert endpoints.get("getAlbum", 0) <= 3, endpoints
PY
  api GET '/v1/library/recent-albums?limit=100' \
    > "$OUTPUT_ROOT/recent-albums-after-cellular-check.json"
  python3 - "$OUTPUT_ROOT/recent-albums-after-cellular-check.json" <<'PY'
import datetime, json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value.get("sort") == "recentlyAdded", value
seen_unranked = False
previous_rank = None
previous_created = None
for album in value.get("albums", []):
    rank = album.get("recentlyAddedRank")
    if rank is not None:
        assert not seen_unranked, value
        assert previous_rank is None or previous_rank < rank, value
        previous_rank = rank
        continue
    seen_unranked = True
    created = album.get("serverCreatedAt")
    assert created is not None, album
    parsed = datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))
    if previous_created is not None:
        assert previous_created >= parsed, value
    previous_created = parsed
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
  # The predecessor process was intentionally interrupted while it owned the
  # cross-engine catalog lease. A competing request must expose `leaseHeld`,
  # never begin duplicate work. Clone diagnostics use a short, heartbeated
  # lease so this retry can also certify safe recovery without a ten-minute
  # wall-clock wait.
  if [[ -n "$SONG_ID" ]]; then
    for LEASE_RECOVERY_ATTEMPT in $(seq 1 8); do
      if wait_for_candidate_collection; then
        break
      else
        LEASE_WAIT_RESULT=$?
      fi
      if [[ "$LEASE_WAIT_RESULT" -ne 75 ]]; then
        exit 70
      fi
      api GET /v1/sync/status > "$OUTPUT_ROOT/lease-held-$LEASE_RECOVERY_ATTEMPT.json"
      if [[ "$LEASE_RECOVERY_ATTEMPT" == "8" ]]; then
        echo "Interrupted catalog lease did not become recoverable." >&2
        exit 70
      fi
      sleep 2
      api POST /v1/sync/repair \
        > "$OUTPUT_ROOT/identical-repair-retry-$LEASE_RECOVERY_ATTEMPT-start.json"
    done
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
