#!/usr/bin/env bash
# Hermetic checks for macOS notarization auth: macos_notarize.sh, macos_dmg.sh and
# release.sh use the App Store Connect API key (--key/--key-id/--issuer) when given
# one, else the notarytool keychain profile. Stub xcrun/codesign/ditto/uvx record
# argv; nothing is signed, built or submitted.
set -euo pipefail
unset MACOS_NOTARY_PROFILE MACOS_SIGN_IDENTITY NAVIS_LASTFM_API_KEY ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "macos_notarize_test: $*" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-notarize-test-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
tmp="$(cd "${tmp}" && pwd -P)"
mkdir -p "${tmp}/bin" "${tmp}/home"
LOG="${tmp}/log"; export LOG
stub() { printf '#!/bin/bash\nset -euo pipefail\n%s\n' "$2" > "${tmp}/bin/$1"; chmod +x "${tmp}/bin/$1"; }
stub xcrun 'echo "xcrun:$*" >> "$LOG"'
stub codesign 'exit 0'
stub iconutil 'exit 0'
stub uvx 'echo "uvx" >> "$LOG"; for last; do :; done; echo dmg > "$last"'
stub ditto 'for last; do :; done; echo zip > "$last"'
export PATH="${tmp}/bin:${PATH}"

app="${tmp}/Navis.app"
mkdir -p "${app}/Contents"; touch "${app}/Contents/Info.plist"
key="${tmp}/AuthKey_KEYID12345.p8"
printf 'P8-SECRET-CONTENT\n' > "${key}"
key_id=KEYID12345 issuer=11111111-2222-3333-4444-555555555555

out=""
run() { : > "${LOG}"; "$@" > "${tmp}/out" 2>&1 && return 0 || return 1; }
run_ok() { run "$@" || { cat "${tmp}/out" >&2; fail "expected success: $*"; }; out="$(cat "${tmp}/out")"; }
run_bad() { if run "$@"; then fail "expected failure: $*"; fi; out="$(cat "${tmp}/out")"; }
expect_in() { [[ "$2" == *"$1"* ]] || fail "missing '$1' in: $2"; }
expect_not_in() { [[ "$2" != *"$1"* ]] || fail "unexpected '$1' in: $2"; }
submit() { grep '^xcrun:notarytool submit' "${LOG}" || fail "no notarytool submit call"; }
want_key() {
  local s; s="$(submit)"
  expect_in "--key ${key} --key-id ${key_id} --issuer ${issuer} --wait" "${s}"
  expect_not_in '--keychain-profile' "${s}"
  expect_not_in 'P8-SECRET' "$(cat "${LOG}" "${tmp}/out")"
}
want_profile() {
  local s; s="$(submit)"
  expect_in '--keychain-profile prof --wait' "${s}"
  expect_not_in '--key' "${s/--keychain-profile/}"
}

# macos_notarize.sh (--flag=value)
N=("${SCRIPT_DIR}/macos_notarize.sh" "--app=${app}" "--output=${tmp}/out.zip" --identity=id)
run_ok "${N[@]}" "--notary-key=${key}" "--notary-key-id=${key_id}" "--notary-issuer=${issuer}"; want_key
run_ok "${N[@]}" --notary-profile=prof; want_profile
MACOS_NOTARY_PROFILE=prof run_ok "${N[@]}"; want_profile
MACOS_NOTARY_PROFILE=prof run_ok "${N[@]}" "--notary-key=${key}" "--notary-key-id=${key_id}" "--notary-issuer=${issuer}"; want_key
run_bad "${N[@]}"
expect_in 'notary' "${out}"; expect_in '--notary-key' "${out}"; expect_in '--notary-profile' "${out}"
[[ ! -s "${LOG}" ]] || fail "notarytool ran without credentials"
run_bad "${N[@]}" "--notary-key=${key}" "--notary-key-id=${key_id}"
expect_in '--notary-issuer' "${out}"
run_bad "${N[@]}" "--notary-key=${tmp}/nope.p8" "--notary-key-id=${key_id}" "--notary-issuer=${issuer}"
expect_in 'readable' "${out}"
[[ ! -s "${LOG}" ]] || fail "notarytool ran with a bad key file"
echo "macos_notarize.sh: API key preferred, profile fallback, neither fails OK"

# macos_dmg.sh (--flag value)
D=("${SCRIPT_DIR}/macos_dmg.sh" --app "${app}" --output "${tmp}/Navis.dmg" --sign-identity id)
run_ok "${D[@]}" --notary-key "${key}" --notary-key-id "${key_id}" --notary-issuer "${issuer}"; want_key
run_ok "${D[@]}" --notary-profile prof; want_profile
run_bad "${D[@]}" --notary-key "${key}" --notary-key-id "${key_id}"
expect_in '--notary-issuer' "${out}"
run_bad "${D[@]}" --notary-key "${tmp}/nope.p8" --notary-key-id "${key_id}" --notary-issuer "${issuer}"
expect_in 'readable' "${out}"
run_bad "${SCRIPT_DIR}/macos_dmg.sh" --app "${app}" --output "${tmp}/Navis.dmg" --notary-key "${key}" --notary-key-id "${key_id}" --notary-issuer "${issuer}"
expect_in '--sign-identity' "${out}"
run_ok "${SCRIPT_DIR}/macos_dmg.sh" --app "${app}" --output "${tmp}/Navis.dmg"
expect_not_in 'notarytool' "$(cat "${LOG}")"
echo "macos_dmg.sh: API key preferred, profile fallback, unsigned skips notarization OK"

# release.sh --macos-notarize picks the key when the ASC variables and file exist.
repo="${tmp}/repo"
mkdir -p "${repo}/tool/lib" "${repo}/macos/Runner"
cp "${SCRIPT_DIR}/release.sh" "${SCRIPT_DIR}/release_tag_guard.sh" "${SCRIPT_DIR}/dev_build_number.py" "${repo}/tool/"
cp "${SCRIPT_DIR}/lib/"{release_dist,release_notes,r2_tags,github_release}.sh "${repo}/tool/lib/"
printf 'version: 1.5.0+10500\n' > "${repo}/pubspec.yaml"
printf 'build/\ndist/\ntool/release.env\n*.zip\n*.dmg\n' > "${repo}/.gitignore"
# Fake signers: record argv and write the output asset release.sh expects.
cat > "${repo}/tool/macos_notarize.sh" <<'FAKE'
#!/bin/bash
echo "macos_notarize:$*" >> "$LOG"
for a; do [[ "$a" != --output=* ]] || echo zip > "${a#--output=}"; done
FAKE
cat > "${repo}/tool/macos_dmg.sh" <<'FAKE'
#!/bin/bash
echo "macos_dmg:$*" >> "$LOG"
while (( $# )); do [[ "$1" != --output ]] || echo dmg > "$2"; shift; done
FAKE
chmod +x "${repo}/tool/macos_notarize.sh" "${repo}/tool/macos_dmg.sh"
(cd "${repo}" && git init -q && git add -A && git -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixture)
stub uname 'echo Darwin'
stub xcodebuild 'exit 0'
stub sha256sum 'exit 0'
stub dart 'echo "## Navis fixture notes"'
stub flutter 'echo "flutter:$*" >> "$LOG"; mkdir -p "$PWD/build/macos/Build/Products/Release/Navis.app"'
export HOME="${tmp}/home"
default_key="${HOME}/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
mkdir -p "$(dirname "${default_key}")"; cp "${key}" "${default_key}"
# rel [VAR=value ...]: one build-only macOS release run with the given environment.
rel() { rm -rf "${repo}/dist"; : > "${LOG}"; (cd "${repo}" && env MACOS_SIGN_IDENTITY=id "$@" ./tool/release.sh v1.5.0 --build-only --skip-checks --targets=macos --macos-notarize) > "${tmp}/out" 2>&1; }
rel_ok() { rel "$@" || { cat "${tmp}/out" >&2; fail "expected success: $*"; }; out="$(cat "${tmp}/out")"; }
rel_bad() { if rel "$@"; then fail "expected failure: $*"; fi; out="$(cat "${tmp}/out")"; }
asc=(ASC_KEY_ID="${key_id}" ASC_ISSUER_ID="${issuer}")

rel_ok "${asc[@]}" MACOS_NOTARY_PROFILE=prof
calls="$(cat "${LOG}")"
expect_in "macos_notarize:--app=" "${calls}"
expect_in "--notary-key=${default_key} --notary-key-id=${key_id} --notary-issuer=${issuer}" "${calls}"
expect_in "macos_dmg:--app " "${calls}"
expect_in "--notary-key ${default_key} --notary-key-id ${key_id} --notary-issuer ${issuer}" "${calls}"
expect_not_in 'notary-profile' "${calls}"
expect_not_in 'P8-SECRET' "${calls}${out}"
# ASC_KEY_PATH overrides the default location.
rm "${default_key}"
rel_ok "${asc[@]}" "ASC_KEY_PATH=${key}"
expect_in "--notary-key=${key} " "$(cat "${LOG}")"
# Without a key file the profile is the fallback.
rel_ok "${asc[@]}" MACOS_NOTARY_PROFILE=prof
calls="$(cat "${LOG}")"
expect_in '--notary-profile=prof' "${calls}"; expect_in '--notary-profile prof' "${calls}"
expect_not_in 'notary-key' "${calls}"
rel_ok MACOS_NOTARY_PROFILE=prof
expect_in '--notary-profile=prof' "$(cat "${LOG}")"
# Neither: fail before any build, naming both options and no values.
rel_bad "${asc[@]}"
expect_in 'ASC_KEY_ID' "${out}"; expect_in 'MACOS_NOTARY_PROFILE' "${out}"
expect_not_in "${key_id}" "${out}"; expect_not_in "${issuer}" "${out}"
[[ ! -s "${LOG}" ]] || fail "tools ran before the notary preflight"
rel_bad
[[ ! -s "${LOG}" ]] || fail "tools ran before the notary preflight"
echo "release.sh: --macos-notarize passes the API key, falls back to the profile, preflight names both OK"
