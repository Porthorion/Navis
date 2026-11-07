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
cp "${SCRIPT_DIR}/lib/"{release_dist,lastfm_key_defines,r2_tags,github_release,scan_artifact_secret}.sh "${repo}/tool/lib/"
cp "${SCRIPT_DIR}/../ios/ExportOptions.plist" "${repo}/ios/"
printf 'version: 1.5.0+10500\n' > "${repo}/pubspec.yaml"
printf 'build/\ndist/\ntool/release.env\n*.zip\n' > "${repo}/.gitignore"
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
stub dart 'exit 0'
# A stale IPA left in build/ios/ipa must be gone before flutter runs.
stub flutter 'echo "flutter:$*" >> "$LOG"
[[ "${PATH%%:*}" == /usr/bin ]] || echo "PATH does not start with /usr/bin" >> "$LOG"
dir="$PWD/build/ios/ipa"
[[ -z "$(ls -A "$dir" 2>/dev/null)" ]] || { echo "stale IPA present" >> "$LOG"; exit 1; }
mkdir -p "$dir"
python3 -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1], \"w\").writestr(\"Payload/App\", \"ipa \" + sys.argv[2])" "$dir/Navis.ipa" "${LEAK_INTO_IPA:-}"'
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

# An iOS-only run publishes nothing, so a non-build-only run is refused up front.
(cd "${repo}" && ./tool/release.sh v1.5.0 --skip-checks --targets=ios > "${tmp}/out" 2>&1) && fail "ios-only publish accepted"
expect_in 'not published' "$(cat "${tmp}/out")"
[[ ! -s "${LOG}" ]] || fail "ios-only publish built something"

# App Store builds need a plain version, so the dev channel is refused.
asc run_bad --targets=ios --ios-upload --channel=dev
expect_in 'stable' "${out}"
[[ ! -s "${LOG}" ]] || fail "dev-channel upload built something"

# A staged bundle cannot be combined with an upload.
(cd "${repo}" && ./tool/release.sh v1.5.0 --publish-from=dist/v1.5.0 --ios-upload > "${tmp}/out" 2>&1) && fail "--publish-from with --ios-upload accepted"
expect_in 'cannot be combined' "$(cat "${tmp}/out")"

# Build only: export-options build, no ad-hoc, no upload, IPA left in place.
mkdir -p "${repo}/build/ios/ipa" && echo stale > "${repo}/build/ios/ipa/Old.ipa"
run_ok --targets=ios
calls="$(cat "${LOG}")"
expect_in 'flutter:build ipa --release --export-options-plist=' "${calls}"
expect_in 'ios/ExportOptions.plist' "${calls}"
expect_not_in 'ad-hoc' "${calls}"; expect_not_in 'PATH does not start' "${calls}"; expect_not_in 'export-method' "${calls}"
expect_not_in 'xcrun' "${calls}"
first_number="$(sed -n 's/.*--build-number=\([0-9]*\).*/\1/p' "${LOG}")"
[[ "${first_number}" -gt 10500 ]] || fail "iOS build number missing or not allocated: ${first_number}"
expect_in "build/ios/ipa/Navis.ipa" "${out}"
[[ ! -e "${repo}/build/ios/ipa/Old.ipa" ]] || fail "stale IPA survived"
[[ -z "$(find "${repo}" -maxdepth 1 -name '*.ipa')" ]] || fail "IPA copied into the release assets"
[[ ! -e "${repo}/dist" ]] || fail "iOS-only build staged an empty bundle"

# Upload: altool gets the freshly built IPA and the default key file location.
asc run_ok --targets=ios --ios-upload
calls="$(cat "${LOG}")"
want="xcrun:altool --upload-app -t ios -f ${repo}/build/ios/ipa/Navis.ipa --api-key ${key_id} --api-issuer ${issuer} --p8-file-path ${key_file}"
expect_in "${want}" "${calls}"
[[ "${calls}" == flutter:*$'\n'xcrun:* ]] || fail "upload must follow the build: ${calls}"
second_number="$(sed -n 's/.*--build-number=\([0-9]*\).*/\1/p' "${LOG}")"
[[ "${second_number}" -gt "${first_number}" ]] || fail "build number did not increase: ${first_number} -> ${second_number}"
expect_not_in "${secret}" "${out}"

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
LEAK_INTO_IPA=fixture-lastfm-key NAVIS_LASTFM_API_KEY=fixture-lastfm-key asc run_bad --targets=ios --ios-upload
expect_in 'plaintext Last.fm API key' "${out}"
expect_not_in 'xcrun' "$(cat "${LOG}")"

# iOS beside another target: the upload follows every build, and no IPA is staged.
asc run_ok --targets=ios,windows --windows-ssh=fixture@builder --ios-upload
calls="$(cat "${LOG}")"
[[ "${calls}" == flutter:*$'\n'windows:*$'\n'xcrun:* ]] || fail "upload must follow all builds: ${calls}"
[[ -f "${repo}/dist/v1.5.0/navis-v1.5.0-windows.zip" ]] || fail "windows asset not staged"
[[ -z "$(find "${repo}/dist" -name '*.ipa')" ]] || fail "IPA staged into the bundle"
rm -rf "${repo}/dist"

# A failed upload fails the release.
XCRUN_FAIL=1 asc run_bad --targets=ios --ios-upload

echo "ios release: upload flag, credential preflight, export-options build, stale IPA, altool arguments OK"
