#!/usr/bin/env bash
# tool/r2_update_diagnostics.sh — Linux end-to-end check of the R2 updater against the real
# bucket on the staging channel: missing manifest, signed offer, verified download, corrupt
# asset, forged manifest, then a full apply + swap + relaunch. Deletes its staging objects on exit.
# Needs the R2 settings and signing key from tool/release.env (see docs/release-r2.md).
set -uo pipefail
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ROOT="$WT/build/r2-update-diagnostics/$STAMP"
HANDSHAKE="$ROOT/handshake.json"
LOG="$ROOT/navis.log"
BUNDLE="$WT/build/linux/x64/profile/bundle"
mkdir -p "$ROOT" && chmod 700 "$ROOT"
python3 - "$(python3 tool/diagnostics_profile.py primary-db)" "$ROOT/clone.sqlite" <<'PY'
import sqlite3, sys
s = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True); t = sqlite3.connect(sys.argv[2])
s.backup(t); t.execute('DELETE FROM play_queue') if t.execute("select 1 from sqlite_master where name='play_queue'").fetchone() else None
t.commit(); t.close()
PY
chmod 600 "$ROOT/clone.sqlite"

set -a; source tool/release.env; set +a
S=(--aws-sigv4 "aws:amz:auto:s3" --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY")
B="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET/navis"
PASS=0; FAIL=0
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
FPID=0
cleanup() {
  [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null
  (( FPID > 0 )) && kill "$FPID" 2>/dev/null
  pkill -f "$BUNDLE/navis" 2>/dev/null
  for v in v1.4.4 v1.4.5 v1.4.6; do
    for f in navis-$v-linux.tar.gz SHA256SUMS.staging; do curl -s -o /dev/null "${S[@]}" -X DELETE "$B/releases/$v/$f"; done
  done
  curl -s -o /dev/null "${S[@]}" -X DELETE "$B/channels/staging/manifest.json"
  echo "cleanup done; staging objects deleted"
}
trap cleanup EXIT

wait_handshake() {
  for _ in $(seq 1 600); do [[ -s "$HANDSHAKE" ]] && break; sleep 1; done
  [[ -s "$HANDSHAKE" ]] || { echo "no handshake; see $LOG"; exit 70; }
  read -r PORT TOKEN APP_PID < <(python3 -c 'import json,sys;v=json.load(open(sys.argv[1]));print(v["port"],v["token"],v["pid"])' "$HANDSHAKE")
  for _ in $(seq 1 60); do curl -sf -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/health" >/dev/null && return; sleep 1; done
  echo "health never OK"; exit 70
}
api() { curl -s -X "$1" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' ${3:+-d "$3"} "http://127.0.0.1:$PORT$2"; }
field() { python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get(sys.argv[1]))' "$1"; }

echo "==> launching clone (profile, channel=staging) — root $ROOT"
flutter run -d linux --profile \
  --dart-define=NAVIS_UPDATE_CHANNEL=staging \
  --dart-define=NAVIS_APP_ID_SUFFIX=.dev \
  --dart-define=NAVIS_APP_NAME='Navis Update Diagnostics' \
  --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
  --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
  --dart-define="NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE=$HANDSHAKE" \
  --dart-define="NAVIS_SYNC_DIAGNOSTICS_ROOT=$ROOT" \
  --dart-define="NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$ROOT/clone.sqlite" \
  >>"$LOG" 2>&1 &
FPID=$!
wait_handshake
echo "    app pid $APP_PID port $PORT"

# 1. No manifest yet on staging -> fetch_failed, nothing offered.
R="$(api POST /v1/diagnostics/update/check)"; echo "    $R"
[[ "$(field rejectReason <<<"$R")" == "fetch_failed" ]] && ok "missing manifest -> fetch_failed" || bad "missing manifest: $R"

# Update payload: the running bundle plus a marker file.
PKG="$ROOT/pkg"; mkdir -p "$PKG"
mk_tar() { local v=$1; rm -rf "$PKG/b"; cp -a "$BUNDLE" "$PKG/b"; echo "$v" > "$PKG/b/R2_UPDATE_MARKER"; tar -czf "$PKG/navis-$v-linux.tar.gz" -C "$PKG/b" .; }

# 2. Valid release v1.4.4 -> offered, verified download.
mk_tar v1.4.4
./tool/r2_publish.sh publish --tag=v1.4.4 --channel=staging "$PKG/navis-v1.4.4-linux.tar.gz" | tail -2
R="$(api POST /v1/diagnostics/update/check)"; echo "    $R"
[[ "$(field tag <<<"$R")" == "v1.4.4" && "$(field signatureValid <<<"$R")" == "True" && "$(field assetKey <<<"$R")" == "linuxPortable" ]] && ok "signed manifest offers v1.4.4 (linuxPortable)" || bad "offer: $R"
R="$(api POST /v1/diagnostics/update/download)"; echo "    $R"
AP="$(field artifactPath <<<"$R")"
if [[ "$(field downloaded <<<"$R")" == "True" && -f "$AP" && "$(sha256sum < "$AP" | cut -d' ' -f1)" == "$(sha256sum < "$PKG/navis-v1.4.4-linux.tar.gz" | cut -d' ' -f1)" ]]; then ok "download verified, bytes match"; else bad "download: $R"; fi

# 3. Corrupt asset at origin (bare URL never fetched publicly) -> integrity_mismatch, file removed.
mk_tar v1.4.5
./tool/r2_publish.sh publish --tag=v1.4.5 --channel=staging "$PKG/navis-v1.4.5-linux.tar.gz" | tail -1
head -c "$(stat -c %s "$PKG/navis-v1.4.5-linux.tar.gz")" /dev/urandom > "$PKG/corrupt"
curl -s -o /dev/null -w "    corrupt PUT %{http_code}\n" "${S[@]}" -T "$PKG/corrupt" "$B/releases/v1.4.5/navis-v1.4.5-linux.tar.gz"
R="$(api POST /v1/diagnostics/update/download)"; echo "    $R"
[[ "$(field downloadError <<<"$R")" == "integrity_mismatch" && "$(field downloaded <<<"$R")" == "False" ]] && ok "corrupt download rejected (integrity_mismatch)" || bad "corrupt: $R"
ls "$(dirname "$AP")" | grep -q "v1.4.5" && bad "corrupt file left on disk" || ok "corrupt file deleted"

# 4. Manifest signed by another key -> invalid_signature.
curl -s "https://downloads.porthorion.com/navis/channels/staging/manifest.json?x=$RANDOM" -o "$PKG/good.json"
jq -r .payload "$PKG/good.json" | base64 -d > "$PKG/p.json"
openssl genpkey -algorithm ed25519 -out "$PKG/other.pem" 2>/dev/null
openssl pkeyutl -sign -inkey "$PKG/other.pem" -rawin -in "$PKG/p.json" -out "$PKG/s.bin"
jq -cn --arg p "$(base64 -w0 "$PKG/p.json")" --arg s "$(base64 -w0 "$PKG/s.bin")" '{payload:$p,signature:$s}' > "$PKG/forged.json"
curl -s -o /dev/null "${S[@]}" -T "$PKG/forged.json" -H 'Cache-Control: no-cache' "$B/channels/staging/manifest.json"
R="$(api POST /v1/diagnostics/update/check)"; echo "    $R"
[[ "$(field rejectReason <<<"$R")" == "invalid_signature" && "$(field tag <<<"$R")" == "None" ]] && ok "forged manifest rejected" || bad "forged: $R"

# 5. Full apply of a valid v1.4.6: download, verify, extract, swap, relaunch.
curl -s -o /dev/null "${S[@]}" -T "$PKG/good.json" -H 'Cache-Control: no-cache' "$B/channels/staging/manifest.json"
mk_tar v1.4.6
./tool/r2_publish.sh publish --tag=v1.4.6 --channel=staging "$PKG/navis-v1.4.6-linux.tar.gz" | tail -1
rm -f "$BUNDLE/R2_UPDATE_MARKER"
OLD_PID=$APP_PID
rm -f "$HANDSHAKE"
R="$(api POST /v1/diagnostics/update/download '{"apply":true}')"; echo "    $R"
[[ "$(field applying <<<"$R")" == "True" ]] && ok "apply started" || bad "apply: $R"
wait_handshake
echo "    relaunched pid $APP_PID (old $OLD_PID)"
[[ "$APP_PID" != "$OLD_PID" ]] && ok "app relaunched as a new process" || bad "same pid"
[[ "$(cat "$BUNDLE/R2_UPDATE_MARKER" 2>/dev/null)" == "v1.4.6" ]] && ok "install dir now holds the v1.4.6 package" || bad "marker missing in $BUNDLE"
[[ "$(readlink -f /proc/$APP_PID/exe)" == "$BUNDLE/navis" ]] && ok "relaunched from the swapped bundle" || bad "exe is $(readlink -f /proc/$APP_PID/exe)"
[[ ! -e "$BUNDLE.backup" ]] && ok "backup cleaned up" || bad "backup left behind"

echo "==> $PASS passed, $FAIL failed"
api POST /v1/shutdown >/dev/null
