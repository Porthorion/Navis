#!/usr/bin/env bash
# Hermetic iOS release tests: release.sh runs in a throwaway git repo with
# stubbed flutter/xcodebuild/xcrun/uname. No build, signing or upload happens.
set -euo pipefail
unset NAVIS_LASTFM_API_KEY ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "ios_release_test: $*" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-ios-release-test-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
tmp="$(cd "${tmp}" && pwd -P)"

# Spaces in the repo path must not break the IPA path handed to altool.
repo="${tmp}/repo with space"
home="${tmp}/home"
mkdir -p "${repo}/tool/lib" "${repo}/ios" "${tmp}/bin" "${home}"
cp "${SCRIPT_DIR}/release.sh" "${SCRIPT_DIR}/release_tag_guard.sh" "${SCRIPT_DIR}/dev_build_number.py" "${repo}/tool/"
cp "${SCRIPT_DIR}/lib/"{release_dist,release_notes,lastfm_key_defines,r2_tags,github_release,scan_artifact_secret}.sh "${repo}/tool/lib/"
cp "${SCRIPT_DIR}/../ios/ExportOptions.plist" "${repo}/ios/"
printf 'version: 1.5.0+10500\n' > "${repo}/pubspec.yaml"
printf 'build/\ndist/\ntool/release.env\n*.zip\n*.ipa\n' > "${repo}/.gitignore"
# A fake Windows builder: proves the upload waits for every target.
printf '#!/bin/bash\necho "windows:$*" >> "$LOG"\necho zip > "$PWD/navis-v1.5.0-windows.zip"\n' > "${repo}/tool/remote_build_windows.sh"
chmod +x "${repo}/tool/remote_build_windows.sh"
(
  cd "${repo}"
  git init -q
  git add -A
  git -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixture
)

LOG="${tmp}/log"
export LOG
stub() { printf '#!/bin/bash\nset -euo pipefail\n%s\n' "$2" > "${tmp}/bin/$1"; chmod +x "${tmp}/bin/$1"; }
stub uname 'echo Darwin'
stub xcodebuild 'exit 0'
stub sha256sum 'exit 0'
stub dart 'echo "## Navis fixture notes"'
# Two builds, told apart by the subcommand. Stale outputs of either must be
# gone before flutter runs, and only the sideload build may carry the define.
cat > "${tmp}/bin/flutter" <<'STUB'
#!/bin/bash
set -euo pipefail
echo "flutter:$*" >> "$LOG"
[[ "${PATH%%:*}" == /usr/bin ]] || echo "PATH does not start with /usr/bin" >> "$LOG"
if [[ "$1 $2" == "build ios" ]]; then
  args=" $* "
  [[ "$args" == *" --release "* && "$args" == *" --no-codesign "* && "$args" == *" --dart-define=NAVIS_IOS_SIDELOAD=true "* ]] || { echo "sideload build flags wrong" >> "$LOG"; exit 1; }
  [[ "$*" != *--build-number* && "$*" != *export-options* ]] || { echo "sideload build mixed with App Store flags" >> "$LOG"; exit 1; }
  app="$PWD/build/ios/iphoneos/Runner.app"
  [[ ! -e "$app" ]] || { echo "stale sideload app present" >> "$LOG"; exit 1; }
  mkdir -p "$app"
  python3 -I -c "import plistlib, sys; plistlib.dump({\"CFBundleShortVersionString\": \"1.5.0\", \"CFBundleVersion\": \"${BAD_BUILD:-10500}\"}, open(sys.argv[1], \"wb\"))" "$app/Info.plist"
  printf 'runner %s' "${LEAK_INTO_SIDELOAD:-}" > "$app/Runner"
  [[ "${SIDELOAD_NO_APP:-}" != 1 ]] || rm -rf "$app"
elif [[ "$1 $2" == "build ipa" ]]; then
  [[ "$*" != *NAVIS_IOS_SIDELOAD* && "$*" != *--no-codesign* ]] || { echo "App Store build carries the sideload define" >> "$LOG"; exit 1; }
  dir="$PWD/build/ios/ipa"
  [[ -z "$(ls -A "$dir" 2>/dev/null)" ]] || { echo "stale IPA present" >> "$LOG"; exit 1; }
  mkdir -p "$dir"
  python3 -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1], \"w\").writestr(\"Payload/App\", \"ipa \" + sys.argv[2])" "$dir/Navis.ipa" "${LEAK_INTO_IPA:-}"
else
  echo "unexpected flutter call" >> "$LOG"; exit 1
fi
STUB
chmod +x "${tmp}/bin/flutter"
stub ssh 'exit 0'
stub scp 'exit 0'
stub xcrun 'echo "xcrun:$*" >> "$LOG"; [[ "${XCRUN_FAIL:-}" != 1 ]]'
export PATH="${tmp}/bin:${PATH}" HOME="${home}"

key_id="KEYID12345"
issuer="11111111-2222-3333-4444-555555555555"
secret="P8-SECRET-CONTENT"
key_file="${home}/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
mkdir -p "$(dirname "${key_file}")"
printf '%s\n' "${secret}" > "${key_file}"

# r2_publish.sh gives the sideload IPA its manifest key and the App Store IPA none.
eval "$(sed -n '/^asset_key_for()/,/^}/p' "${SCRIPT_DIR}/r2_publish.sh")"
[[ "$(asset_key_for navis-v1.5.2-ios-sideload.ipa)" == iosSideload ]] || fail "sideload IPA manifest key"
[[ "$(asset_key_for navis-dev-v1.5.2-dev.1-ios-sideload.ipa)" == iosSideload ]] || fail "dev sideload IPA manifest key"
[[ -z "$(asset_key_for Navis.ipa)" ]] || fail "App Store IPA must have no manifest key"

out=""
run() { : > "${LOG}"; (cd "${repo}" && ./tool/release.sh v1.5.0 --build-only --skip-checks "$@") > "${tmp}/out" 2>&1 && return 0 || return 1; }
run_ok() { run "$@" || { cat "${tmp}/out" >&2; fail "expected success: $*"; }; out="$(cat "${tmp}/out")"; }
run_bad() { if run "$@"; then fail "expected failure: $*"; fi; out="$(cat "${tmp}/out")"; }
expect_in() { [[ "$2" == *"$1"* ]] || fail "missing '$1' in: $2"; }
expect_not_in() { [[ "$2" != *"$1"* ]] || fail "unexpected '$1' in: $2"; }
asc() { ASC_KEY_ID="${key_id}" ASC_ISSUER_ID="${issuer}" "$@"; }

# --ios-upload needs ios in the targets.
run_bad --targets=linux --ios-upload
expect_in 'Error: --ios-upload needs ios among the --targets' "${out}"
[[ ! -s "${LOG}" ]] || fail "tools ran before the target check"

# Missing credentials fail before any build, naming the variable, never a value.
ASC_ISSUER_ID="${issuer}" run_bad --targets=ios --ios-upload
expect_in 'ASC_KEY_ID' "${out}"
ASC_KEY_ID="${key_id}" run_bad --targets=ios --ios-upload
expect_in 'ASC_ISSUER_ID' "${out}"
rm "${key_file}"
asc run_bad --targets=ios --ios-upload
expect_in 'AuthKey_<ASC_KEY_ID>.p8' "${out}"
expect_not_in "${key_id}" "${out}"; expect_not_in "${issuer}" "${out}"
[[ ! -s "${LOG}" ]] || fail "flutter ran despite missing credentials"
ASC_KEY_ID="${key_id}" ASC_ISSUER_ID="${issuer}" ASC_KEY_PATH="${tmp}/nope.p8" run_bad --targets=ios --ios-upload
expect_in 'ASC_KEY_PATH' "${out}"; expect_not_in "${tmp}/nope.p8" "${out}"
[[ ! -s "${LOG}" ]] || fail "flutter ran despite a bad ASC_KEY_PATH"
printf '%s\n' "${secret}" > "${key_file}"

# An iOS-only dev run has nothing to publish (the sideload IPA is stable-only),
# so a non-build-only run is refused up front.
(cd "${repo}" && ./tool/release.sh v1.5.0-dev.1 --skip-checks --targets=ios --channel=dev > "${tmp}/out" 2>&1) && fail "ios-only dev publish accepted"
expect_in 'not published' "$(cat "${tmp}/out")"
[[ ! -s "${LOG}" ]] || fail "ios-only dev publish built something"
# An iOS-only upload builds no release asset, so it cannot be published either.
(cd "${repo}" && ./tool/release.sh v1.5.0 --skip-checks --targets=ios --ios-upload > "${tmp}/out" 2>&1) && fail "ios-only upload publish accepted"
expect_in 'not published' "$(cat "${tmp}/out")"

# App Store builds need a plain version, so the dev channel is refused.
asc run_bad --targets=ios --ios-upload --channel=dev
expect_in 'stable' "${out}"
[[ ! -s "${LOG}" ]] || fail "dev-channel upload built something"

# A staged bundle cannot be combined with an upload.
(cd "${repo}" && ./tool/release.sh v1.5.0 --publish-from=dist/v1.5.0 --ios-upload > "${tmp}/out" 2>&1) && fail "--publish-from with --ios-upload accepted"
expect_in 'cannot be combined' "$(cat "${tmp}/out")"

# Build only: export-options build, no ad-hoc, no upload, IPA left in place.
mkdir -p "${repo}/build/ios/ipa" && echo stale > "${repo}/build/ios/ipa/Old.ipa"
mkdir -p "${repo}/build/ios/iphoneos/Runner.app" && echo stale > "${repo}/build/ios/iphoneos/Runner.app/stale"
run_ok --targets=ios
calls="$(cat "${LOG}")"
expect_in 'flutter:build ipa --release --export-options-plist=' "${calls}"
expect_in 'flutter:build ios --release --no-codesign' "${calls}"
expect_in '--dart-define=NAVIS_IOS_SIDELOAD=true' "${calls}"
[[ "$(grep -c NAVIS_IOS_SIDELOAD "${LOG}")" == 1 ]] || fail "the sideload define must reach exactly one build: ${calls}"
[[ "${calls}" == *'flutter:build ios'*$'\n'*'flutter:build ipa'* ]] || fail "sideload build must run before the App Store build: ${calls}"
expect_not_in 'stale' "${calls}"
expect_in 'ios/ExportOptions.plist' "${calls}"
expect_not_in 'ad-hoc' "${calls}"; expect_not_in 'PATH does not start' "${calls}"; expect_not_in 'export-method' "${calls}"
expect_not_in 'xcrun' "${calls}"
first_number="$(sed -n 's/.*--build-number=\([0-9]*\).*/\1/p' "${LOG}")"
[[ "${first_number}" -gt 10500 ]] || fail "iOS build number missing or not allocated: ${first_number}"
expect_in "build/ios/ipa/Navis.ipa" "${out}"
[[ ! -e "${repo}/build/ios/ipa/Old.ipa" ]] || fail "stale IPA survived"
# The sideload IPA is the only IPA among the release assets; the App Store IPA never is.
[[ "$(find "${repo}" -maxdepth 1 -name '*.ipa' -exec basename {} \;)" == navis-v1.5.0-ios-sideload.ipa ]] || fail "unexpected IPA among the release assets"
[[ "$(ls "${repo}/dist/v1.5.0" | grep -c '\.ipa$')" == 1 && -s "${repo}/dist/v1.5.0/navis-v1.5.0-ios-sideload.ipa" ]] || fail "sideload IPA not staged"
[[ ! -e "${repo}/dist/v1.5.0/Navis.ipa" ]] || fail "App Store IPA staged"
# The unsigned IPA is a Payload/Runner.app zip that keeps Info.plist and its version.
python3 -I - "${repo}/dist/v1.5.0/navis-v1.5.0-ios-sideload.ipa" <<'PY' || fail "sideload IPA layout"
import plistlib, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
plist = plistlib.loads(z.read("Payload/Runner.app/Info.plist"))
assert plist["CFBundleShortVersionString"] == "1.5.0" and plist["CFBundleVersion"] == "10500", plist
assert "Payload/Runner.app/Runner" in z.namelist(), z.namelist()
assert not any("stale" in n for n in z.namelist()), z.namelist()
PY
grep -qx 'navis-v1.5.0-ios-sideload.ipa' "${repo}/dist/v1.5.0/assets.txt" || fail "sideload IPA missing from assets.txt"
# A plain iOS build stages dist/<tag>, so the same run cannot repeat until it is moved.
run_bad --targets=ios
expect_in 'already exists' "${out}"
rm -rf "${repo}/dist"

# Upload: altool gets the freshly built IPA and the default key file location.
asc run_ok --targets=ios --ios-upload
calls="$(cat "${LOG}")"
want="xcrun:altool --upload-app -t ios -f ${repo}/build/ios/ipa/Navis.ipa --api-key ${key_id} --api-issuer ${issuer} --p8-file-path ${key_file}"
expect_in "${want}" "${calls}"
[[ "${calls}" == flutter:*$'\n'xcrun:* ]] || fail "upload must follow the build: ${calls}"
second_number="$(sed -n 's/.*--build-number=\([0-9]*\).*/\1/p' "${LOG}")"
[[ "${second_number}" -gt "${first_number}" ]] || fail "build number did not increase: ${first_number} -> ${second_number}"
expect_not_in "${secret}" "${out}"
# An iOS-only upload is a TestFlight iteration: no sideload build, nothing staged,
# so it repeats (and each repeat gets a higher build number).
expect_not_in 'flutter:build ios' "${calls}"
[[ ! -e "${repo}/dist" ]] || fail "iOS-only upload staged a bundle"
asc run_ok --targets=ios --ios-upload
third_number="$(sed -n 's/.*--build-number=\([0-9]*\).*/\1/p' "${LOG}")"
[[ "${third_number}" -gt "${second_number}" ]] || fail "repeat upload build number did not increase"
[[ ! -e "${repo}/dist" ]] || fail "repeat iOS-only upload staged a bundle"

# ASC_KEY_PATH overrides the default location; credentials may come from release.env.
cp "${key_file}" "${tmp}/custom key.p8"; rm "${key_file}"
printf 'ASC_KEY_ID=%s\nASC_ISSUER_ID=%s\n' "${key_id}" "${issuer}" > "${repo}/tool/release.env"
ASC_KEY_PATH="${tmp}/custom key.p8" run_ok --targets=ios --ios-upload
expect_in "--p8-file-path ${tmp}/custom key.p8" "$(cat "${LOG}")"
rm "${repo}/tool/release.env"; printf '%s\n' "${secret}" > "${key_file}"

# iOS builds need a macOS host.
stub uname 'echo Linux'
run_bad --targets=ios
expect_in 'macOS host' "${out}"
stub uname 'echo Darwin'

# Relative ASC_KEY_PATH from another cwd: altool gets an absolute path.
mkdir -p "${tmp}/elsewhere"
cp "${key_file}" "${tmp}/elsewhere/rel key.p8"
: > "${LOG}"
(cd "${tmp}/elsewhere" && ASC_KEY_ID="${key_id}" ASC_ISSUER_ID="${issuer}" ASC_KEY_PATH="rel key.p8" \
  "${repo}/tool/release.sh" v1.5.0 --build-only --skip-checks --targets=ios --ios-upload) > "${tmp}/out" 2>&1 \
  || { cat "${tmp}/out" >&2; fail "relative ASC_KEY_PATH run failed"; }
expect_in "--p8-file-path ${tmp}/elsewhere/rel key.p8" "$(cat "${LOG}")"

# The IPA secret scan runs, and a leaked Last.fm key fails the release before any upload.
NAVIS_LASTFM_API_KEY=fixture-lastfm-key asc run_ok --targets=ios --ios-upload
expect_in 'Scanning Navis.ipa' "${out}"
NAVIS_LASTFM_API_KEY=fixture-lastfm-key run_ok --targets=ios
expect_in 'Scanning navis-v1.5.0-ios-sideload.ipa' "${out}"
rm -rf "${repo}/dist"
LEAK_INTO_IPA=fixture-lastfm-key NAVIS_LASTFM_API_KEY=fixture-lastfm-key asc run_bad --targets=ios --ios-upload
expect_in 'plaintext Last.fm API key' "${out}"
expect_not_in 'xcrun' "$(cat "${LOG}")"

# A leaked key in the sideload IPA fails the release before the App Store build.
LEAK_INTO_SIDELOAD=fixture-lastfm-key NAVIS_LASTFM_API_KEY=fixture-lastfm-key asc run_bad --targets=ios
expect_in 'Scanning navis-v1.5.0-ios-sideload.ipa' "${out}"
expect_in 'plaintext Last.fm API key' "${out}"
expect_not_in 'flutter:build ipa' "$(cat "${LOG}")"
expect_not_in 'xcrun' "$(cat "${LOG}")"

# The unsigned app must still carry the release version and build number, and exist.
BAD_BUILD=1 run_bad --targets=ios
expect_in 'Info.plist' "${out}"
SIDELOAD_NO_APP=1 run_bad --targets=ios
expect_in 'Runner.app' "${out}"

# The dev channel builds the App Store flavour only: no sideload build or asset.
run_ok --targets=ios --channel=dev
calls="$(cat "${LOG}")"
expect_in 'flutter:build ipa' "${calls}"
expect_not_in 'flutter:build ios' "${calls}"
expect_not_in 'NAVIS_IOS_SIDELOAD' "${calls}"
[[ ! -e "${repo}/dist" ]] || fail "dev iOS build staged an empty bundle"

# iOS beside another target: the upload follows every build, and no IPA is staged.
asc run_ok --targets=ios,windows --windows-ssh=fixture@builder --ios-upload
calls="$(cat "${LOG}")"
[[ "${calls}" == flutter:*$'\n'windows:*$'\n'xcrun:* ]] || fail "upload must follow all builds: ${calls}"
[[ -f "${repo}/dist/v1.5.0/navis-v1.5.0-windows.zip" ]] || fail "windows asset not staged"
[[ "$(find "${repo}/dist" -name '*.ipa' -exec basename {} \;)" == navis-v1.5.0-ios-sideload.ipa ]] || fail "only the sideload IPA belongs in the bundle"
rm -rf "${repo}/dist"

# A failed upload fails the release.
XCRUN_FAIL=1 asc run_bad --targets=ios --ios-upload

echo "ios release: upload flag, credential preflight, export-options build, stale IPA, altool arguments, sideload IPA OK"
