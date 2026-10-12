#!/usr/bin/env bash
# Sourced helpers for Linux diagnostics. Sourcing only defines functions;
# callers own shell options, traps, profiles, logs and scenario-specific defines.
# Local helpers may override these defaults when their behavior differs.
# Globals below are supplied by the caller, never initialized by this library.

# api <method> <route> [body]; uses BASE_URL and TOKEN, without a curl timeout.
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

# Uses FLUTTER_PID; terminate and reap the task-owned launcher if still alive.
cleanup_app() {
  if (( FLUTTER_PID > 0 )) && kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
    kill "$FLUTTER_PID" >/dev/null 2>&1 || true
    wait "$FLUTTER_PID" >/dev/null 2>&1 || true
  fi
}

# Default app-only trap handler. Callers with other resources keep their own trap handler.
cleanup() {
  cleanup_app
}

# Uses FIXTURE_PID as well as FLUTTER_PID; preserves the fixture guard and wait.
cleanup_fixture_app() {
  cleanup_app
  if (( FIXTURE_PID > 0 )) && kill -0 "$FIXTURE_PID" >/dev/null 2>&1; then
    kill "$FIXTURE_PID" >/dev/null 2>&1 || true
    wait "$FIXTURE_PID" >/dev/null 2>&1 || true
  fi
}

# Uses AUDIO_MODULE; preserve audio-module unload after launcher cleanup.
cleanup_audio_app() {
  cleanup_app
  if [[ -n "$AUDIO_MODULE" ]]; then pactl unload-module "$AUDIO_MODULE" || true; fi
}

# Uses FLUTTER_PID and FIXTURE_PID; retain the original loop and its status.
cleanup_processes() {
  for process_id in "$FLUTTER_PID" "$FIXTURE_PID"; do
    if (( process_id > 0 )) && kill -0 "$process_id" >/dev/null 2>&1; then
      kill "$process_id" >/dev/null 2>&1 || true
      wait "$process_id" >/dev/null 2>&1 || true
    fi
  done
}

# Uses FLUTTER_PID; authenticated shutdown, bounded wait, then forced cleanup.
stop_app() {
  if (( FLUTTER_PID > 0 )) && kill -0 "$FLUTTER_PID" >/dev/null 2>&1; then
    api POST /v1/shutdown >/dev/null 2>&1 || true
    local deadline=$((SECONDS + 30))
    while kill -0 "$FLUTTER_PID" >/dev/null 2>&1 && (( SECONDS < deadline )); do
      sleep 1
    done
    cleanup_app
  fi
  FLUTTER_PID=0
}

# Mute through the API and require both persisted and effective volume to be zero.
mute_and_verify() {
  local response
  response="$(api POST /v1/playback/volume '{"value":0}')"
  python3 - "$response" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value.get("volume") == 0, value
assert value.get("effectivePlayerVolume") == 0, value
PY
}

# assert_adjustments <status-json> <speed-percent> <pitch-semitones>
assert_adjustments() {
  python3 - "$1" "$2" "$3" <<'PYCODE'
import json, math, sys
value = json.load(open(sys.argv[1]))
speed = float(sys.argv[2]); pitch = float(sys.argv[3]); factor = 2 ** (pitch / 12)
assert value['failure'] is None, value
assert value['pitchSupported'] is True, value
assert math.isclose(value['speedPercent'], speed, abs_tol=1e-6), value
assert math.isclose(value['pitchSemitones'], pitch, abs_tol=1e-6), value
assert math.isclose(value['persistedSpeed'], 1 + speed/100, abs_tol=1e-6), value
assert math.isclose(value['persistedPitchSemitones'], pitch, abs_tol=1e-6), value
for key in ('playerSpeed', 'crossfadeSpeed'):
    assert math.isclose(value['engine'][key], 1 + speed/100, abs_tol=1e-6), value
for key in ('playerPitchFactor', 'crossfadePitchFactor'):
    assert math.isclose(value['engine'][key], factor, abs_tol=1e-6), value
PYCODE
}

# wait_for_idle <output-json>; uses APP_LOG for the original timeout message.
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

# Default readiness poll; scripts with additional readiness assertions keep theirs local.
wait_for_presentation() {
  for _ in $(seq 1 90); do
    if api GET /v1/presentation/status | python3 -c 'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if value.get("appReady") and value.get("screenshotReady") else 1)'; then return; fi
    sleep 1
  done
  echo "Presentation did not become ready. See $APP_LOG" >&2
  exit 70
}

# Uses DIAGNOSTICS_FAILURE_PREFIX and APP_LOG; exit code remains 70.
fail() {
  echo "$DIAGNOSTICS_FAILURE_PREFIX: $*" >&2
  [[ -n "$APP_LOG" ]] && echo "See $APP_LOG" >&2
  exit 70
}

# wait_for <route> <Python-predicate> <output-json> [timeout-seconds]
# Uses DIAGNOSTICS_POLL_INTERVAL (seconds) and the caller's fail helper.
wait_for() {
  local route="$1" predicate="$2" output="$3" timeout="${4:-180}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if api GET "$route" > "$output" 2>/dev/null &&
      python3 -c "import json,sys; v=json.load(open(sys.argv[1])); raise SystemExit(0 if ($predicate) else 1)" \
        "$output"; then
      return
    fi
    sleep "$DIAGNOSTICS_POLL_INTERVAL"
  done
  fail "timed out waiting for $route to satisfy: $predicate ($(cat "$output" 2>/dev/null))"
}

# shutdown_app <label> [output-basename]; uses OUTPUT_ROOT and FLUTTER_PID.
shutdown_app() {
  local output_name="${2:-shutdown-$1.json}"
  api POST /v1/shutdown > "$OUTPUT_ROOT/$output_name" || true
  wait "$FLUTTER_PID" || true
  FLUTTER_PID=0
}

# start_fixture <fixture-password> [extra-server-args...]
# Uses PROJECT_DIR, OUTPUT_ROOT, CREDENTIAL_FILE, FIXTURE_HANDSHAKE, FIXTURE_LOG;
# sets FIXTURE_PID and FIXTURE_PORT. Auth lifecycle keeps its different startup local.
start_fixture() {
  local password="$1"
  shift
  printf '%s\n' "$password" > "$CREDENTIAL_FILE"
  chmod 600 "$CREDENTIAL_FILE"
  python3 "$PROJECT_DIR/tool/auth_lifecycle_fixture_server.py" \
    --handshake "$FIXTURE_HANDSHAKE" \
    --failure-flag "$OUTPUT_ROOT/fixture-sync-failure" \
    "$@" \
    >>"$FIXTURE_LOG" 2>&1 &
  FIXTURE_PID=$!
  local deadline=$((SECONDS + 30))
  while [[ ! -s "$FIXTURE_HANDSHAKE" ]] && (( SECONDS < deadline )); do
    kill -0 "$FIXTURE_PID" >/dev/null 2>&1 ||
      fail "fixture server exited; see $FIXTURE_LOG"
    sleep 1
  done
  [[ -s "$FIXTURE_HANDSHAKE" ]] || fail "fixture server did not start"
  FIXTURE_PORT="$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["port"])' \
    "$FIXTURE_HANDSHAKE")"
}

# Download launch_app <label>; uses DIAGNOSTICS_APP_NAME and PROFILE_DB,
# CREDENTIAL_FILE, PROJECT_DIR, OUTPUT_ROOT, HANDSHAKE. Sets APP_LOG,
# FLUTTER_PID, TOKEN and BASE_URL; preserves the exec subshell and 600-second poll.
launch_app() {
  local label="$1"
  cleanup_app
  FLUTTER_PID=0
  APP_LOG="$OUTPUT_ROOT/$label-navis.log"
  rm -f "$HANDSHAKE"
  : > "$APP_LOG"
  mkdir -p "$OUTPUT_ROOT/support"
  awk '/^version:/ {split($2, p, "+"); print p[1]; exit}' \
    "$PROJECT_DIR/pubspec.yaml" > "$OUTPUT_ROOT/support/changelog_seen_version.txt"
  (
    cd "$PROJECT_DIR"
    exec flutter run -d linux --profile \
      --dart-define=NAVIS_UPDATE_CHANNEL=dev \
      --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
      --dart-define="NAVIS_APP_NAME=$DIAGNOSTICS_APP_NAME" \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS_MUTED=true \
      --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$PROFILE_DB" \
      --dart-define="NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=$CREDENTIAL_FILE"
  ) >>"$APP_LOG" 2>&1 &
  FLUTTER_PID=$!
  local deadline=$((SECONDS + 600))
  while [[ ! -s "$HANDSHAKE" ]] && (( SECONDS < deadline )); do
    kill -0 "$FLUTTER_PID" >/dev/null 2>&1 ||
      fail "Navis exited before diagnostics startup"
    sleep 1
  done
  [[ -s "$HANDSHAKE" ]] || fail "timed out waiting for the diagnostics API"
  local port
  read -r port TOKEN < <(python3 -c \
    'import json,sys; v=json.load(open(sys.argv[1])); print(v["port"], v["token"])' \
    "$HANDSHAKE")
  BASE_URL="http://127.0.0.1:$port"
  api GET /v1/health > "$OUTPUT_ROOT/$label-health.json"
}

# launch_audio_app <app-name>; uses AUDIO_SINK, CLONE_DB, HANDSHAKE,
# OUTPUT_ROOT, APP_LOG and optional NAVIS_DIAGNOSTICS_CREDENTIAL_PATH.
# Sets FLUTTER_PID, PORT, TOKEN, APP_PID and BASE_URL; preserves the Pulse sink.
launch_audio_app() {
  rm -f "$HANDSHAKE"
  # Like presentation_diagnostics.sh: an optional mode-600 password file
  # signs the clone in where the system keyring holds no Navis password.
  local -a credential_define=()
  if [[ -n "${NAVIS_DIAGNOSTICS_CREDENTIAL_PATH:-}" ]]; then
    if [[ ! -f "$NAVIS_DIAGNOSTICS_CREDENTIAL_PATH" ]]; then
      echo "Diagnostics credential file was not found." >&2
      exit 66
    fi
    credential_define+=(
      "--dart-define=NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH=$NAVIS_DIAGNOSTICS_CREDENTIAL_PATH"
    )
  fi
  PULSE_SINK="$AUDIO_SINK" flutter run -d linux --profile \
    --dart-define=NAVIS_UPDATE_CHANNEL=dev \
    --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
    --dart-define="NAVIS_APP_NAME=$1" \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
    --dart-define="NAVIS_DIAGNOSTICS_AUDIO_DEVICE=pulse/$AUDIO_SINK" \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$OUTPUT_ROOT" \
    --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$CLONE_DB" \
    "${credential_define[@]}" \
    >>"$APP_LOG" 2>&1 &
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

  read -r PORT TOKEN APP_PID < <(
    python3 - "$HANDSHAKE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["port"], value["token"], value["pid"])
PY
  )
  BASE_URL="http://127.0.0.1:$PORT"
}

# launch <dart-define-args...>; clone fixture launch, using PROJECT_DIR,
# OUTPUT_ROOT, HANDSHAKE and APP_LOG; sets FLUTTER_PID, PORT, TOKEN and BASE_URL.
# Callers pass their exact define arrays; the original subshell and unguarded poll remain.
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
      "$@" \
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
