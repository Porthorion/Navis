#!/usr/bin/env bash
set -euo pipefail

# Controller-backed loopback certification for the unchanged-indexes new-album
# case. Both the Subsonic server and the database are isolated fixtures.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="${NAVIS_DIAGNOSTICS_PRIMARY_DB:-$HOME/Documents/navis.sqlite.sqlite}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/manual-discovery-diagnostics/$STAMP-clone"
CLONE_DB="$OUTPUT_ROOT/navis-diagnostics.sqlite"
HANDSHAKE="$OUTPUT_ROOT/handshake.json"
FIXTURE_HANDSHAKE="$OUTPUT_ROOT/fixture-handshake.json"
CREDENTIAL_FILE="$OUTPUT_ROOT/fixture-password"
APP_LOG="$OUTPUT_ROOT/navis.log"
FLUTTER_PID=0
FIXTURE_PID=0

[[ -f "$SOURCE_DB" ]] || { echo "Primary database not found: $SOURCE_DB" >&2; exit 66; }
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"

cleanup() {
  for process_id in "$FLUTTER_PID" "$FIXTURE_PID"; do
    if (( process_id > 0 )) && kill -0 "$process_id" >/dev/null 2>&1; then
      kill "$process_id" >/dev/null 2>&1 || true
      wait "$process_id" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT INT TERM

printf '%s\n' 'navis-manual-discovery-fixture' > "$CREDENTIAL_FILE"
chmod 600 "$CREDENTIAL_FILE"
fixture_args=(--annotation-log "$OUTPUT_ROOT/annotations.jsonl")
if [[ "${NAVIS_MANUAL_DISCOVERY_OMIT_EXISTING:-0}" == "1" ]]; then
  fixture_args+=(--omit-existing-artist-album)
fi
python3 "$PROJECT_DIR/tool/auth_lifecycle_fixture_server.py" \
  --handshake "$FIXTURE_HANDSHAKE" \
  --failure-flag "$OUTPUT_ROOT/unused-failure-flag" \
  --scenario manual-discovery "${fixture_args[@]}" >"$OUTPUT_ROOT/fixture.log" 2>&1 &
FIXTURE_PID=$!
for _ in $(seq 1 30); do [[ -s "$FIXTURE_HANDSHAKE" ]] && break; sleep 1; done
[[ -s "$FIXTURE_HANDSHAKE" ]] || { echo "Fixture startup failed" >&2; exit 70; }

python3 - "$SOURCE_DB" "$CLONE_DB" "$FIXTURE_HANDSHAKE" <<'PY'
import datetime, json, sqlite3, sys, time
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
source.backup(target)
source.close()
fixture = json.load(open(sys.argv[3], encoding="utf-8"))
server = target.execute("SELECT id, capabilities FROM server_config WHERE is_authenticated = 1 ORDER BY id LIMIT 1").fetchone()
if server is None:
    raise SystemExit("clone has no authenticated server")
server_id, raw_capabilities = server
try:
    capabilities = json.loads(raw_capabilities) if raw_capabilities else {}
except (TypeError, json.JSONDecodeError):
    capabilities = {}
navis = capabilities.setdefault("navis", {})
if not isinstance(navis, dict):
    navis = {}
    capabilities["navis"] = navis
for key in ("libraryPendingIndexesFingerprint", "libraryPendingIndexesCursor", "libraryPendingIndexesOffset", "libraryPendingIndexesArtistIds", "librarySyncFailureDiagnostics", "librarySyncFailureRecordedAt", "bulkSongSearchWildcardQuery"):
    navis.pop(key, None)
cursor = datetime.datetime.fromtimestamp(fixture["indexesLastModified"] / 1000, tz=datetime.timezone.utc).isoformat().replace("+00:00", "Z")
navis.update({"libraryIndexesCursor": cursor, "libraryHealthCheckedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"), "libraryFreshness": "current"})
now = int(time.time())
state_columns = {row[1] for row in target.execute("PRAGMA table_info(library_sync_state)")}
if "next_automatic_check_at" not in state_columns:
    target.execute("ALTER TABLE library_sync_state ADD COLUMN next_automatic_check_at INTEGER")
target.execute("DELETE FROM library_sync_work")
# Clone-only: drop the source profile's downloads and download settings so
# the app cannot move, delete or re-tag the user's real files.
target.execute("DELETE FROM cached_tracks")
target.execute("DELETE FROM download_queue")
settings_columns = {row[1] for row in target.execute("PRAGMA table_info(app_settings)")}
for column, value in (("custom_download_folder_enabled", 0), ("custom_download_folder_path", None), ("custom_download_folder_storage_kind", "filesystem"), ("auto_download_starred_on_wifi", 0)):
    if column in settings_columns:
        target.execute(f"UPDATE app_settings SET {column} = ?", (value,))
target.execute("DELETE FROM star_sync_queue")
album_columns = {row[1] for row in target.execute("PRAGMA table_info(albums)")}
if "songs_verified_at" not in album_columns:
    target.execute("ALTER TABLE albums ADD COLUMN songs_verified_at INTEGER")
for table in ("library_sync_candidate_artists", "library_sync_candidate_albums", "library_sync_candidate_songs"):
    target.execute(f"DELETE FROM {table}")
target.execute("UPDATE server_config SET name=?, url=?, username=?, api_version=?, capabilities=?, last_synced=?, last_full_synced=?, is_authenticated=1 WHERE id=?", ("Navis manual discovery fixture", f"http://127.0.0.1:{fixture['port']}", "diagnostics", "1.16.1", json.dumps(capabilities, separators=(",", ":")), now, now, server_id))
target.execute("INSERT OR IGNORE INTO library_sync_state (server_id) VALUES (?)", (server_id,))
target.execute("UPDATE library_sync_state SET last_checked_at=?, last_catalog_synced_at=?, last_auxiliary_synced_at=?, candidate_generation=NULL, candidate_status=NULL, candidate_started_at=NULL, candidate_carried_forward_count=0, deletion_candidate_count=0, next_automatic_check_at=? WHERE server_id=?", (now, now, now, now + 3600, server_id))
# This fixture certifies one new album discovery. The copied primary catalog is
# otherwise intentionally already hydrated so unrelated historical song work
# cannot mask the terminal result of the app-owned manual check.
target.execute("UPDATE albums SET songs_hydrated=1, songs_verified_at=?", (now,))
target.execute("INSERT OR REPLACE INTO artists (id, name, album_count, cover_art, is_provisional, is_external) VALUES (?, ?, ?, ?, 0, 0)", ("fixture-existing-artist", "Fixture Existing Artist", 2, "fixture-cover"))
target.execute("INSERT OR REPLACE INTO albums (id, name, artist_id, artist_name, song_count, duration, year, cover_art, songs_hydrated, server_created_at, is_provisional, is_external) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 0, 0)", ("fixture-existing-album", "Fixture Existing Album", "fixture-existing-artist", "Fixture Existing Artist", 1, 4, 2025, "fixture-cover", int(datetime.datetime(2025, 1, 1, tzinfo=datetime.timezone.utc).timestamp())))
target.execute("INSERT OR REPLACE INTO songs (id, title, album_id, artist_id, artist_name, album_name, track, duration, is_provisional, is_external) VALUES (?, ?, ?, ?, ?, ?, 1, 4, 0, 0)", ("fixture-existing-song", "Fixture Existing Tone", "fixture-existing-album", "fixture-existing-artist", "Fixture Existing Artist", "Fixture Existing Album"))
target.execute("UPDATE albums SET songs_hydrated=1, songs_verified_at=? WHERE id='fixture-existing-album'", (now,))
target.commit()
assert target.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
assert not target.execute("PRAGMA foreign_key_check").fetchall()
target.close()
PY
chmod 600 "$CLONE_DB"

launch() {
  rm -f "$HANDSHAKE"
  local data_home="$OUTPUT_ROOT/app-data"
  local version
  version="$(awk '/^version:/ {split($2, p, "+"); print p[1]; exit}' "$PROJECT_DIR/pubspec.yaml")"
  mkdir -p "$data_home/com.navis.app.navis"
  printf '%s\n' "$version" > "$data_home/com.navis.app.navis/changelog_seen_version.txt"
  (
    cd "$PROJECT_DIR"
    env "XDG_DATA_HOME=$data_home" flutter run -d linux --profile \
      --dart-define=NAVIS_UPDATE_CHANNEL=dev \
      --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
      --dart-define=NAVIS_APP_NAME='Navis Manual Discovery Diagnostics' \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
      --dart-define="NAVIS_DIAGNOSTICS_ANNOTATION_FIXTURE=${NAVIS_ANNOTATION_FIXTURE:-false}" \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CLONE_DB" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=$CREDENTIAL_FILE" \
      >>"$APP_LOG" 2>&1
  ) &
  FLUTTER_PID=$!
  for _ in $(seq 1 180); do [[ -s "$HANDSHAKE" ]] && break; sleep 1; done
  [[ -s "$HANDSHAKE" ]] || { echo "App startup failed. See $APP_LOG" >&2; exit 70; }
  read -r PORT TOKEN < <(python3 - "$HANDSHAKE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["port"], value["token"])
PY
)
  BASE_URL="http://127.0.0.1:$PORT"
}

api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl --fail-with-body --silent --show-error -X "$method" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body" "$BASE_URL$path"
  else
    curl --fail-with-body --silent --show-error -X "$method" -H "Authorization: Bearer $TOKEN" "$BASE_URL$path"
  fi
}

wait_for_idle() {
  local output="$1"
  for _ in $(seq 1 180); do
    api GET /v1/sync/status > "$output"
    if python3 - "$output" <<'PY'
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1])).get("requestActive") else 1)
PY
    then return; fi
    sleep 1
  done
  echo "Sync did not settle. See $APP_LOG" >&2
  exit 70
}

wait_for_presentation() {
  for _ in $(seq 1 90); do
    if api GET /v1/presentation/status | python3 -c 'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if value.get("appReady") and value.get("screenshotReady") else 1)'; then return; fi
    sleep 1
  done
  echo "Presentation did not become ready. See $APP_LOG" >&2
  exit 70
}

capture() {
  local label="$1" manifest="$2"
  local screenshot_path mean
  for _ in $(seq 1 5); do
    api POST /v1/presentation/screenshot "$(python3 - "$label" <<'PY'
import json, sys
print(json.dumps({"label": sys.argv[1]}))
PY
)" > "$manifest"
    screenshot_path="$(python3 - "$manifest" "$OUTPUT_ROOT" <<'PY'
import hashlib, json, os, sys
value = json.load(open(sys.argv[1]))
path = os.path.realpath(os.path.join(sys.argv[2], value["artifact"]))
assert os.path.commonpath([os.path.realpath(sys.argv[2]), path]) == os.path.realpath(sys.argv[2])
data = open(path, "rb").read()
assert data[:8] == b"\x89PNG\r\n\x1a\n" and hashlib.sha256(data).hexdigest() == value["sha256"]
print(path)
PY
    )"
    # A compositor may briefly return an all-black frame after a Linux
    # restart. File existence alone is not visual validation.
    mean="$(identify -format '%[fx:mean.r]' "$screenshot_path")"
    if awk -v mean="$mean" 'BEGIN { exit !(mean > 0.001) }'; then
      printf '%s\n' "$screenshot_path"
      return
    fi
    sleep 2
  done
  echo "Screenshot remained visually blank: $label" >&2
  return 1
}

launch
api GET /v1/health > "$OUTPUT_ROOT/health.json"
wait_for_presentation
wait_for_idle "$OUTPUT_ROOT/status-before.json"
api GET '/v1/library/album?id=fixture-new-album&verifySongs=true' > "$OUTPUT_ROOT/album-before.json"
api GET '/v1/library/album?id=fixture-existing-album&verifySongs=true' > "$OUTPUT_ROOT/existing-album-before.json"
python3 - "$OUTPUT_ROOT/album-before.json" "$OUTPUT_ROOT/existing-album-before.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])) == {"id": "fixture-new-album", "exists": False}
assert json.load(open(sys.argv[2])).get("exists") is True
PY
api POST /v1/diagnostics/overrides \
  '{"networkType":"offline","requestReporting":true}' \
  > "$OUTPUT_ROOT/offline-overrides.json"
if [[ "${NAVIS_ANNOTATION_FIXTURE:-false}" == "true" ]]; then
  for entry in 'song fixture-existing-song' 'album fixture-existing-album' 'artist fixture-existing-artist'; do
    read -r item_type item_id <<< "$entry"
    api POST /v1/diagnostics/local-mutation "{\"type\":\"$item_type\",\"id\":\"$item_id\",\"field\":\"starred\",\"value\":true}" > /dev/null
  done
  api POST /v1/diagnostics/local-mutation '{"type":"song","id":"fixture-existing-song","field":"rating","value":4}' > /dev/null
  python3 - "$CLONE_DB" <<'VERIFY_QUEUE'
import sqlite3, sys
with sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True) as db:
    assert db.execute("SELECT COUNT(*) FROM star_sync_queue").fetchone()[0] == 4
VERIFY_QUEUE
fi

api POST /v1/sync/check '{}' > "$OUTPUT_ROOT/offline-check-start.json"
wait_for_idle "$OUTPUT_ROOT/offline-check-status.json"
api GET /v1/sync/ledger > "$OUTPUT_ROOT/offline-sync-ledger.json"
api GET '/v1/library/album?id=fixture-new-album&verifySongs=true' > "$OUTPUT_ROOT/offline-album.json"
python3 - "$OUTPUT_ROOT/offline-check-status.json" \
  "$OUTPUT_ROOT/offline-sync-ledger.json" "$OUTPUT_ROOT/offline-album.json" <<'PY'
import json, sys
status = json.load(open(sys.argv[1]))
assert status["status"] == "deferred", status
assert status["planKind"] == "deltaReconcile", status
assert status["planReason"] == "manualCatalogDiscoveryOffline", status
events = json.load(open(sys.argv[2]))["events"]
terminal = next(event for event in reversed(events) if event.get("cause") == "manualCheck" and event.get("phase") == "terminal")
assert terminal["planKind"] == "deltaReconcile", terminal
assert terminal["planReason"] == "manualCatalogDiscoveryOffline", terminal
assert json.load(open(sys.argv[3])) == {"id": "fixture-new-album", "exists": False}
PY
if [[ "${NAVIS_MANUAL_DISCOVERY_FORCE_MANUAL_RESUME:-0}" == "1" ]]; then
  # Queue a higher-priority album detail without dispatching it. The following
  # Wi-Fi manual check must still resume its catalog delta, not display this
  # target's misleading 0 / 1 hydration progress as a completed refresh.
  api POST /v1/sync/fixture/queue-target \
    '{"targetKind":"album","entityId":"fixture-existing-album"}' \
    > "$OUTPUT_ROOT/queued-target.json"
  python3 - "$OUTPUT_ROOT/queued-target.json" <<'PY'
import json, sys
queued = json.load(open(sys.argv[1]))
assert queued["status"] == "queued", queued
assert queued["targetKind"] == "album", queued
# The preceding offline manual check is itself durable catalog work. The
# fixture must add the targeted hydration alongside it, rather than replacing
# it or dispatching either job.
assert queued["pendingWork"] >= 2, queued
PY
fi
api POST /v1/diagnostics/overrides \
  '{"networkType":"wifi","nativeMetered":false,"requestReporting":true}' \
  > "$OUTPUT_ROOT/online-overrides.json"
resume_path='/v1/sync/automatic'
resume_body=''
resume_cause='automatic'
if [[ "${NAVIS_MANUAL_DISCOVERY_FORCE_MANUAL_RESUME:-0}" == "1" ]]; then
  resume_path='/v1/sync/check'
  resume_body='{}'
  resume_cause='manualCheck'
fi
api POST "$resume_path" "$resume_body" > "$OUTPUT_ROOT/reconnect-resume-start.json"
wait_for_idle "$OUTPUT_ROOT/status-after.json"
api GET '/v1/library/album?id=fixture-new-album&verifySongs=true' > "$OUTPUT_ROOT/album-after.json"
api GET '/v1/library/album?id=fixture-existing-album&verifySongs=true' > "$OUTPUT_ROOT/existing-album-after.json"
api GET /v1/sync/ledger > "$OUTPUT_ROOT/sync-ledger.json"
if [[ "${NAVIS_ANNOTATION_FIXTURE:-false}" == "true" ]]; then
  delivery_verified=0
  for _ in $(seq 1 45); do
    if python3 - "$CLONE_DB" "$OUTPUT_ROOT/annotations.jsonl" <<'VERIFY_DELIVERY'
import json, os, sqlite3, sys
with sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True) as db:
    if db.execute("SELECT COUNT(*) FROM star_sync_queue").fetchone()[0]:
        raise SystemExit(1)
rows = [json.loads(line) for line in open(sys.argv[2])] if os.path.exists(sys.argv[2]) else []
expected = [
    {"endpoint":"star","parameters":{"id":["fixture-existing-song"]}},
    {"endpoint":"star","parameters":{"albumId":["fixture-existing-album"]}},
    {"endpoint":"star","parameters":{"artistId":["fixture-existing-artist"]}},
    {"endpoint":"setRating","parameters":{"id":["fixture-existing-song"],"rating":["4"]}},
]
assert all(row in rows for row in expected), rows
VERIFY_DELIVERY
    then delivery_verified=1; break; fi
    sleep 1
  done
  [[ "$delivery_verified" == "1" ]] || { echo "Annotation delivery verification failed" >&2; exit 1; }
  python3 - "$CLONE_DB" <<'VERIFY_EMPTY'
import sqlite3, sys
with sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True) as db:
    assert db.execute("SELECT COUNT(*) FROM star_sync_queue").fetchone()[0] == 0
VERIFY_EMPTY
fi

python3 - "$resume_cause" "${NAVIS_MANUAL_DISCOVERY_FORCE_MANUAL_RESUME:-0}" "$OUTPUT_ROOT/status-after.json" "$OUTPUT_ROOT/album-after.json" "$OUTPUT_ROOT/existing-album-after.json" "$OUTPUT_ROOT/sync-ledger.json" <<'PY'
import json, sys
resume_cause = sys.argv[1]
queued_target = sys.argv[2] == "1"
status = json.load(open(sys.argv[3]))
album = json.load(open(sys.argv[4]))
assert album == {"id": "fixture-new-album", "exists": True, "songsHydrated": True, "songCount": 1, "persistedSongCount": 1}, album
existing = json.load(open(sys.argv[5]))
assert existing.get("exists") and existing.get("songsHydrated") and existing.get("persistedSongCount") == 1, existing
events = json.load(open(sys.argv[6]))["events"]
terminal = next(event for event in reversed(events) if event.get("cause") == resume_cause and event.get("phase") == "terminal")
assert terminal["planKind"] == "deltaReconcile" and terminal["planReason"] == "resumeDeltaReconcile", terminal
for endpoint in ("getIndexes", "getNewestAlbumList2", "getArtist", "getAlbum"):
    assert terminal["endpointRequests"].get(endpoint, 0) >= 1, terminal
if queued_target:
    assert status["pendingWork"] == 1, status
PY
if [[ "${NAVIS_MANUAL_DISCOVERY_FORCE_MANUAL_RESUME:-0}" == "1" ]]; then
  api POST /v1/sync/target \
    '{"targetKind":"album","entityId":"fixture-existing-album"}' \
    > "$OUTPUT_ROOT/queued-target-drain-start.json"
  wait_for_idle "$OUTPUT_ROOT/queued-target-drain-status.json"
  api GET /v1/sync/ledger > "$OUTPUT_ROOT/queued-target-drain-ledger.json"
  python3 - "$OUTPUT_ROOT/queued-target-drain-status.json" "$OUTPUT_ROOT/queued-target-drain-ledger.json" <<'PY'
import json, sys
status = json.load(open(sys.argv[1]))
assert status["pendingWork"] == 0, status
events = json.load(open(sys.argv[2]))["events"]
terminal = next(event for event in reversed(events) if event.get("cause") == "targetHydration" and event.get("phase") == "terminal")
assert terminal["targetKind"] == "album" and terminal["result"] in ("succeeded", "partial"), terminal
PY
fi
api POST /v1/presentation/navigate '{"location":"/library/albums/fixture-new-album"}' > "$OUTPUT_ROOT/navigation.json"
sleep 5
capture manual-discovery "$OUTPUT_ROOT/screenshot.json" > "$OUTPUT_ROOT/screenshot-path.txt"
api POST /v1/shutdown > "$OUTPUT_ROOT/shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0

launch
wait_for_presentation
wait_for_idle "$OUTPUT_ROOT/restart-status.json"
api GET '/v1/library/album?id=fixture-new-album&verifySongs=true' > "$OUTPUT_ROOT/restart-album.json"
api GET '/v1/library/album?id=fixture-existing-album&verifySongs=true' > "$OUTPUT_ROOT/restart-existing-album.json"
python3 - "$OUTPUT_ROOT/restart-album.json" "$OUTPUT_ROOT/restart-existing-album.json" <<'PY'
import json, sys
album = json.load(open(sys.argv[1]))
assert album.get("exists") and album.get("songsHydrated") and album.get("persistedSongCount") == 1, album
existing = json.load(open(sys.argv[2]))
assert existing.get("exists") and existing.get("songsHydrated") and existing.get("persistedSongCount") == 1, existing
PY
api POST /v1/presentation/navigate '{"location":"/library/albums/fixture-new-album"}' > "$OUTPUT_ROOT/restart-navigation.json"
sleep 5
capture manual-discovery-restart "$OUTPUT_ROOT/restart-screenshot.json" > "$OUTPUT_ROOT/restart-screenshot-path.txt"
api POST /v1/shutdown > "$OUTPUT_ROOT/restart-shutdown.json" || true
wait "$FLUTTER_PID" || true
FLUTTER_PID=0

if rg -n 'Unhandled Exception|Tried to modify a provider while the widget tree was building|created the database class NavisDatabase multiple times' "$APP_LOG" > "$OUTPUT_ROOT/log-errors.txt"; then
  echo "Runtime log contains a hard-fail pattern. See $APP_LOG" >&2
  exit 1
fi

python3 - "$OUTPUT_ROOT/runtime-validation.json" "$OUTPUT_ROOT/screenshot-path.txt" "$OUTPUT_ROOT/restart-screenshot-path.txt" <<'PY'
import json, sys
json.dump({
    "status": "passed",
    "target": "linux",
    "profile": "isolated-loopback-clone",
    "scenario": "Offline Manual Check for updates retains newest-album discovery and resumes it after reconnect while getIndexes is unchanged; partial artist responses retain existing sibling albums when requested",
    "endpoints": [
        "GET /v1/health", "GET /v1/sync/status", "GET /v1/sync/ledger",
        "GET /v1/library/album", "POST /v1/diagnostics/overrides",
        "POST /v1/sync/check", "POST /v1/sync/automatic",
        "POST /v1/presentation/navigate", "POST /v1/presentation/screenshot",
        "POST /v1/shutdown",
    ],
    "screenshots": [
        open(sys.argv[2], encoding="utf-8").read().strip(),
        open(sys.argv[3], encoding="utf-8").read().strip(),
    ],
    "visualInspection": "required-by-agent",
    "logReview": "no-hard-fail-patterns",
    "cleanRestart": "passed",
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
echo "Manual-discovery diagnostics completed: $OUTPUT_ROOT"
echo "Open and inspect: $(<"$OUTPUT_ROOT/screenshot-path.txt")"
echo "Open and inspect: $(<"$OUTPUT_ROOT/restart-screenshot-path.txt")"
