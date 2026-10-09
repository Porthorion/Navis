#!/usr/bin/env bash
# tool/r2_update_diagnostics_android.sh — Android emulator check of the R2 updater
# (staging channel): offer, verified download, corrupt rejection, forged-manifest rejection.
# Assumes an emulator is booted; set SKIP_BUILD=1 to reuse the last profile APK.
set -uo pipefail
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WT"
export JAVA_HOME=/home/khalifa/android-studio/jbr
ADB=/home/khalifa/Android/Sdk/platform-tools/adb
PKG=com.navis.app.navis.r2test
ROOT=/data/user/0/$PKG/files/diag
APK="$WT/build/app/outputs/flutter-apk/app-sideload-profile.apk"
WORK="$WT/build/r2-android/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$WORK"

set -a; source tool/release.env; set +a
S=(--aws-sigv4 "aws:amz:auto:s3" --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY")
B="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET/navis"
N="$(date +%s)"; V1="v1.4.$N"; V2="v1.4.$((N+1))"
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
cleanup() {
  for v in "$V1" "$V2"; do for f in navis-$v.apk SHA256SUMS.staging; do curl -s -o /dev/null "${S[@]}" -X DELETE "$B/releases/$v/$f"; done; done
  curl -s -o /dev/null "${S[@]}" -X DELETE "$B/channels/staging/manifest.json"
  $ADB uninstall $PKG >/dev/null 2>&1
  echo "cleanup done"
}
trap cleanup EXIT

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  NAVIS_APP_ID_SUFFIX=.r2test NAVIS_SELF_UPDATE=true flutter build apk --profile --flavor sideload --target-platform android-x64 \
    --dart-define=NAVIS_UPDATE_CHANNEL=staging \
    --dart-define=NAVIS_APP_ID_SUFFIX=.r2test \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS=true \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_ROOT=$ROOT \
    --dart-define=NAVIS_SYNC_DIAGNOSTICS_DB_PATH=$ROOT/navis.sqlite \
    > "$WORK/build.log" 2>&1 || { echo "build failed, see $WORK/build.log"; exit 1; }
  (cd android && ./gradlew --stop >/dev/null 2>&1)
fi
[[ -f "$APK" ]] || { echo "no APK at $APK"; ls build/app/outputs/flutter-apk/; exit 1; }

$ADB install -r "$APK" >/dev/null || { echo "install failed"; exit 1; }
$ADB shell run-as $PKG mkdir -p files/diag
# A fresh install otherwise blocks startup on the notification permission prompt.
$ADB shell pm grant $PKG android.permission.POST_NOTIFICATIONS
HS=/sdcard/Android/data/$PKG/files/navis-diagnostics/handshake.json
$ADB shell rm -f $HS
$ADB shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
for _ in $(seq 1 120); do $ADB shell cat $HS 2>/dev/null | grep -q token && break; sleep 1; done
read -r DPORT TOKEN < <($ADB shell cat $HS | python3 -c 'import json,sys;v=json.load(sys.stdin);print(v["port"],v["token"])')
$ADB forward tcp:18999 tcp:$DPORT >/dev/null
api() { curl -s -X "$1" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' ${3:+-d "$3"} "http://127.0.0.1:18999$2"; }
field() { python3 -c 'import json,sys;print(json.loads(sys.stdin.read()).get(sys.argv[1]))' "$1"; }
for _ in $(seq 1 60); do api GET /v1/health | grep -q . && break; sleep 1; done
echo "    version: $($ADB shell dumpsys package $PKG | grep -m1 versionName)"

cp "$APK" "$WORK/navis-$V1.apk"
./tool/r2_publish.sh publish --tag=$V1 --channel=staging "$WORK/navis-$V1.apk" | tail -1
R="$(api POST /v1/diagnostics/update/check)"; echo "    $R"
[[ "$(field tag <<<"$R")" == "$V1" && "$(field assetKey <<<"$R")" == "androidApk" && "$(field signatureValid <<<"$R")" == "True" ]] && ok "Android offered $V1 (androidApk)" || bad "offer: $R"
R="$(api POST /v1/diagnostics/update/download)"; echo "    $R"
AP="$(field artifactPath <<<"$R")"
if [[ "$(field downloaded <<<"$R")" == "True" ]]; then
  GOT="$($ADB exec-out run-as $PKG sha256sum "$AP" 2>/dev/null | cut -d' ' -f1)"
  [[ "$GOT" == "$(sha256sum < "$APK" | cut -d' ' -f1)" ]] && ok "Android download verified, bytes match" || bad "on-device sha $GOT"
else bad "download: $R"; fi

cp "$APK" "$WORK/navis-$V2.apk"
./tool/r2_publish.sh publish --tag=$V2 --channel=staging "$WORK/navis-$V2.apk" | tail -1
head -c "$(stat -c %s "$APK")" /dev/urandom > "$WORK/corrupt"
curl -s -o /dev/null "${S[@]}" -T "$WORK/corrupt" "$B/releases/$V2/navis-$V2.apk"
R="$(api POST /v1/diagnostics/update/download)"; echo "    $R"
[[ "$(field downloadError <<<"$R")" == "integrity_mismatch" ]] && ok "Android corrupt download rejected" || bad "corrupt: $R"
$ADB exec-out run-as $PKG ls "$(dirname "$AP")" 2>/dev/null | grep -q $V2 && bad "corrupt APK left on device" || ok "corrupt APK deleted"

curl -s "https://downloads.porthorion.com/navis/channels/staging/manifest.json?x=$RANDOM" -o "$WORK/good.json"
jq -r .payload "$WORK/good.json" | base64 -d > "$WORK/p.json"
openssl genpkey -algorithm ed25519 -out "$WORK/other.pem" 2>/dev/null
openssl pkeyutl -sign -inkey "$WORK/other.pem" -rawin -in "$WORK/p.json" -out "$WORK/s.bin"
jq -cn --arg p "$(base64 -w0 "$WORK/p.json")" --arg s "$(base64 -w0 "$WORK/s.bin")" '{payload:$p,signature:$s}' > "$WORK/forged.json"
curl -s -o /dev/null "${S[@]}" -T "$WORK/forged.json" -H 'Content-Type: application/json' -H 'Cache-Control: no-cache' "$B/channels/staging/manifest.json"
R="$(api POST /v1/diagnostics/update/check)"; echo "    $R"
[[ "$(field rejectReason <<<"$R")" == "invalid_signature" ]] && ok "Android forged manifest rejected" || bad "forged: $R"

echo "==> $PASS passed, $FAIL failed"
$ADB forward --remove tcp:18999
