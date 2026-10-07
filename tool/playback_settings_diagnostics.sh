#!/usr/bin/env bash
set -euo pipefail

# Verifies that a Playback settings autosave keeps settings other screens own:
# the ListenBrainz account, unmetered-only background sync and the desktop
# volume. It also requires that neither that autosave nor a desktop volume write
# restarts weekly ListenBrainz discovery. The Linux profile app signs in to the
# local loopback fixture with an isolated clone, flips Scrobbling through the
# production switch, and repeats the assertions after a clean restart.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="$(python3 "$PROJECT_DIR/tool/diagnostics_profile.py" primary-db)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="$PROJECT_DIR/build/playback-settings-diagnostics/$STAMP"
CLONE_DB="$OUTPUT_ROOT/navis-playback-settings.sqlite"
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
  # Killing the launcher subshell alone leaves the app running after a failed
  # assertion, so ask the app to exit first.
  if (( FLUTTER_PID > 0 )) && [[ -n "${TOKEN:-}" ]]; then
    api POST /v1/shutdown >/dev/null 2>&1 || true
  fi
  for process_id in "$FLUTTER_PID" "$FIXTURE_PID"; do
    if (( process_id > 0 )) && kill -0 "$process_id" >/dev/null 2>&1; then
      kill "$process_id" >/dev/null 2>&1 || true
      wait "$process_id" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT INT TERM

printf '%s\n' 'navis-playback-settings-fixture' > "$CREDENTIAL_FILE"
chmod 600 "$CREDENTIAL_FILE"
python3 "$PROJECT_DIR/tool/auth_lifecycle_fixture_server.py" \
  --handshake "$FIXTURE_HANDSHAKE" \
  --failure-flag "$OUTPUT_ROOT/unused-failure-flag" \
  >"$OUTPUT_ROOT/fixture.log" 2>&1 &
FIXTURE_PID=$!
for _ in $(seq 1 30); do [[ -s "$FIXTURE_HANDSHAKE" ]] && break; sleep 1; done
[[ -s "$FIXTURE_HANDSHAKE" ]] || { echo "Fixture startup failed" >&2; exit 70; }

# Test setup only: the seeded values stand in for choices made on the Sync
# settings and ListenBrainz screens. Every assertion reads the running app.
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
for key in ("libraryPendingIndexesFingerprint", "libraryPendingIndexesCursor", "libraryPendingIndexesOffset", "libraryPendingIndexesArtistIds", "librarySyncFailureDiagnostics", "librarySyncFailureRecordedAt"):
    navis.pop(key, None)
cursor = datetime.datetime.fromtimestamp(fixture["indexesLastModified"] / 1000, tz=datetime.timezone.utc).isoformat().replace("+00:00", "Z")
navis.update({"libraryIndexesCursor": cursor, "libraryHealthCheckedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"), "libraryFreshness": "current"})
now = int(time.time())
target.execute("DELETE FROM library_sync_work")
# Clone-only: drop the source profile's downloads and download settings so
# the app cannot move, delete or re-tag the user's real files.
target.execute("DELETE FROM cached_tracks")
target.execute("DELETE FROM download_queue")
target.execute("DELETE FROM star_sync_queue")
settings_columns = {row[1] for row in target.execute("PRAGMA table_info(app_settings)")}
for column, value in (
    ("custom_download_folder_enabled", 0),
    ("custom_download_folder_path", None),
    ("custom_download_folder_storage_kind", "filesystem"),
    ("auto_download_starred_on_wifi", 0),
    ("scrobble_enabled", 1),
    ("background_sync_unmetered_only", 0),
    ("listen_brainz_token_valid", 1),
    ("listen_brainz_scrobbling_enabled", 1),
    ("listen_brainz_user_name", "fixture-listener"),
):
    if column in settings_columns:
        target.execute(f"UPDATE app_settings SET {column} = ?", (value,))
for table in ("library_sync_candidate_artists", "library_sync_candidate_albums", "library_sync_candidate_songs"):
    target.execute(f"DELETE FROM {table}")
target.execute("UPDATE server_config SET name=?, url=?, username=?, api_version=?, capabilities=?, last_synced=?, last_full_synced=?, is_authenticated=1 WHERE id=?", ("Navis playback settings fixture", f"http://127.0.0.1:{fixture['port']}", "diagnostics", "1.16.1", json.dumps(capabilities, separators=(",", ":")), now, now, server_id))
target.execute("INSERT OR IGNORE INTO library_sync_state (server_id) VALUES (?)", (server_id,))
target.execute("UPDATE library_sync_state SET last_checked_at=?, last_catalog_synced_at=?, last_auxiliary_synced_at=?, candidate_generation=NULL, candidate_status=NULL, candidate_started_at=NULL, candidate_carried_forward_count=0, deletion_candidate_count=0, next_automatic_check_at=? WHERE server_id=?", (now, now, now, now + 3600, server_id))
target.commit()
assert target.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
assert not target.execute("PRAGMA foreign_key_check").fetchall()
target.close()
PY
chmod 600 "$CLONE_DB"

launch() {
  rm -f "$HANDSHAKE"
  local version
  version="$(awk '/^version:/ {split($2, p, "+"); print p[1]; exit}' "$PROJECT_DIR/pubspec.yaml")"
  # Clone app-support state lives in the run root's support directory.
  mkdir -p "$OUTPUT_ROOT/support"
  printf '%s\n' "$version" > "$OUTPUT_ROOT/support/changelog_seen_version.txt"
  (
    cd "$PROJECT_DIR"
    flutter run -d linux --profile \
      --dart-define=NAVIS_UPDATE_CHANNEL=dev \
      --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
      --dart-define=NAVIS_APP_NAME='Navis Playback Settings Diagnostics' \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS_MUTED=true \
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

shutdown_app() {
  api POST /v1/shutdown > "$OUTPUT_ROOT/shutdown-$1.json" || true
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
}

wait_for_ready() {
  for _ in $(seq 1 180); do
    if api GET /v1/presentation/status | python3 -c 'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if value.get("appReady") and value.get("screenshotReady") else 1)'; then return; fi
    sleep 1
  done
  echo "Presentation did not become ready. See $APP_LOG" >&2
  exit 70
}

# Polls the persisted settings until Scrobbling matches $1, then requires the
# fields other screens own to keep their seeded values.
assert_settings() {
  local scrobble="$1" output="$2"
  for _ in $(seq 1 30); do
    api GET /v1/presentation/playback-settings > "$output"
    if python3 - "$output" "$scrobble" <<'PY'
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1]))["scrobbleEnabled"] == (sys.argv[2] == "true") else 1)
PY
    then
      python3 - "$output" <<'PY'
import json, math, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["backgroundSyncUnmeteredOnly"] is False, value
assert value["listenBrainzTokenValid"] is True, value
assert value["listenBrainzAccountStored"] is True, value
assert math.isclose(value["persistedVolume"], 0.37, abs_tol=0.001), value
PY
      return
    fi
    sleep 0.5
  done
  echo "Scrobbling did not persist as $scrobble. See $output" >&2
  exit 1
}

discover_builds() {
  api GET /v1/presentation/listenbrainz-discover > "$1"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["streamBuilds"])' "$1"
}

# Prints the weekly discovery build count once two reads a second apart agree,
# so the startup settings load has finished restarting it.
settled_discover_builds() {
  local previous current
  previous="$(discover_builds "$1")"
  for _ in $(seq 1 30); do
    sleep 1
    current="$(discover_builds "$1")"
    if [[ "$current" == "$previous" ]]; then
      echo "$current"
      return
    fi
    previous="$current"
  done
  echo "Weekly discovery kept restarting. See $1" >&2
  exit 1
}

# Requires the weekly discovery build count to stay at $1 for three seconds.
assert_discover_builds() {
  local expected="$1" output="$2" current
  for _ in $(seq 1 6); do
    current="$(discover_builds "$output")"
    if [[ "$current" != "$expected" ]]; then
      echo "Weekly discovery restarted ($expected -> $current). See $output" >&2
      exit 1
    fi
    sleep 0.5
  done
}

launch
api GET /v1/health > "$OUTPUT_ROOT/health-initial.json"
wait_for_ready
DISCOVER_BUILDS="$(settled_discover_builds "$OUTPUT_ROOT/discover-initial.json")"
api POST /v1/playback/volume '{"value":0.37}' > "$OUTPUT_ROOT/volume-set.json"
assert_settings true "$OUTPUT_ROOT/settings-seeded.json"
assert_discover_builds "$DISCOVER_BUILDS" "$OUTPUT_ROOT/discover-after-volume.json"
api POST /v1/presentation/navigate '{"location":"/settings/playback"}' \
  > "$OUTPUT_ROOT/navigate-playback.json"
wait_for_ready
api POST /v1/presentation/playback-settings '{"toggle":"scrobble"}' \
  > "$OUTPUT_ROOT/toggle-scrobble.json"
assert_settings false "$OUTPUT_ROOT/settings-after-autosave.json"
assert_discover_builds "$DISCOVER_BUILDS" "$OUTPUT_ROOT/discover-after-autosave.json"
api POST /v1/presentation/screenshot '{"label":"playback-settings"}' \
  > "$OUTPUT_ROOT/screenshot-playback-settings.json"
shutdown_app initial

launch
api GET /v1/health > "$OUTPUT_ROOT/health-restart.json"
wait_for_ready
assert_settings false "$OUTPUT_ROOT/settings-after-restart.json"
DISCOVER_BUILDS="$(settled_discover_builds "$OUTPUT_ROOT/discover-restart.json")"
api POST /v1/presentation/navigate '{"location":"/settings/playback"}' \
  > "$OUTPUT_ROOT/navigate-playback-restart.json"
wait_for_ready
api POST /v1/presentation/playback-settings '{"toggle":"scrobble"}' \
  > "$OUTPUT_ROOT/toggle-scrobble-restart.json"
assert_settings true "$OUTPUT_ROOT/settings-after-restart-autosave.json"
assert_discover_builds "$DISCOVER_BUILDS" \
  "$OUTPUT_ROOT/discover-after-restart-autosave.json"
shutdown_app final

if grep -E 'Unhandled Exception|ERROR:flutter/runtime' "$APP_LOG" >/dev/null; then
  echo "Runtime errors found in $APP_LOG" >&2
  exit 1
fi

trap - EXIT INT TERM
cleanup
echo "Playback settings diagnostics completed: $OUTPUT_ROOT"
