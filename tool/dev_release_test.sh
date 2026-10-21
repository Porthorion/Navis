#!/usr/bin/env bash
# Hermetic release tests: fake Flutter/Android tools and a local fake S3 store.
# No application, credentials, R2 requests or network publication are used.
set -euo pipefail
unset NAVIS_LASTFM_API_KEY NAVIS_RELEASE_NOTES_URL
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/r2_tags.sh"
fail() { echo "dev_release_test: $*" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/navis-dev-release-test-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

for channel in stable dev staging; do
  navis_r2_valid_tag v1.5.0 "${channel}" || fail "plain tag refused"
  for suffix in dev staging; do
    if navis_r2_valid_tag "v1.5.0-${suffix}.10501" "${channel}"; then
      [[ "${channel}" != stable ]] || fail "stable accepted build tag"
    else
      [[ "${channel}" == stable ]] || fail "channel build tag refused"
    fi
  done
  for tag in v1.5.0-beta.1 v1.5.0-dev.0 v1.5.0-dev.01 v1.5.0-dev.-1 v1.5.0-dev.1/evil v1.5; do
    if navis_r2_valid_tag "${tag}" "${channel}"; then fail "invalid tag ${tag}"; fi
  done
done
python3 - "${SCRIPT_DIR}" "${tmp}/counter" <<'PY'
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import sys
import multiprocessing
sys.path.insert(0, sys.argv[1])
from dev_build_number import allocate_build, EPOCH, OFFSET, LIMIT
state = Path(sys.argv[2])
a = allocate_build(state, EPOCH)
b = allocate_build(state, EPOCH)
c = allocate_build(state, EPOCH - 100)
d = allocate_build(state, EPOCH + 86400)
assert a == OFFSET and b == a + 1 and c == b + 1 and d == OFFSET + 86400
with ProcessPoolExecutor(max_workers=4, mp_context=multiprocessing.get_context('fork')) as pool:
    values = list(pool.map(allocate_build, [state] * 16))
assert len(set(values)) == 16 and min(values) > d
(state / 'build-number').write_text(str(LIMIT - 1))
try:
    allocate_build(state, EPOCH)
except ValueError:
    pass
else:
    raise AssertionError('Android limit accepted')
print('build number: repeat, rollback, day boundary, concurrent allocation, Android limit OK')
PY
mkdir -p "${tmp}/repo/tool/lib" "${tmp}/repo/lib/src/utils" "${tmp}/bin" "${tmp}/store" "${tmp}/home"
cp "${SCRIPT_DIR}/r2_publish.sh" "${SCRIPT_DIR}/dev_release.sh" "${SCRIPT_DIR}/dev_app.sh" "${SCRIPT_DIR}/dev_build_number.py" "${tmp}/repo/tool/"
cp "${SCRIPT_DIR}/lib/"{r2_tags,r2_storage,lastfm_key_defines,scan_artifact_secret,github_release}.sh "${tmp}/repo/tool/lib/"
# A disposable key and pin, never the repository's real signing key.
openssl genpkey -algorithm ed25519 -out "${tmp}/test.pem" 2>/dev/null
pub="$(openssl pkey -in "${tmp}/test.pem" -pubout -outform DER | tail -c 32 | base64)"
printf "const updateSigningPublicKey = '%s';\n" "${pub}" > "${tmp}/repo/lib/src/utils/constants.dart"
export R2_ACCOUNT_ID=fake R2_BUCKET=bucket R2_PREFIX=navis R2_ACCESS_KEY_ID=fake R2_SECRET_ACCESS_KEY=fake
export NAVIS_UPDATE_SIGNING_KEY="${tmp}/test.pem"
export FAKE_STORE="${tmp}/store" FAKE_LOG="${tmp}/requests" FAKE_BUILD="${tmp}/build-number"
export PATH="${tmp}/bin:${PATH}" HOME="${tmp}/home"
cat > "${tmp}/bin/curl" <<'PY'
#!/usr/bin/env python3
import hashlib
import os
import json
import base64
from pathlib import Path
import shutil
import sys
from urllib.parse import urlparse
import xml.etree.ElementTree as ET
args = iter(sys.argv[1:])
method, outfile, upload, write_status, url, prefix, token = 'GET', None, None, False, '', '', ''
for arg in args:
    if arg in ('--aws-sigv4', '--user', '-H'):
        next(args)
    elif arg == '-o': outfile = next(args)
    elif arg == '-w': next(args); write_status = True
    elif arg == '-T': upload = next(args); method = 'PUT'
    elif arg == '-X': method = next(args)
    elif arg == '-I': method = 'HEAD'
    elif arg == '--data-urlencode':
        k, v = next(args).split('=', 1)
        if k == 'prefix': prefix = v
        if k == 'continuation-token': token = v
    elif arg.startswith('https://'): url = arg
u = urlparse(url)
key = u.path.lstrip('/')
if u.hostname.endswith('.r2.cloudflarestorage.com'):
    key = key.removeprefix('bucket/')
with open(os.environ['FAKE_LOG'], 'a') as log: log.write(f'{method} {key}\n')
store = Path(os.environ['FAKE_STORE'])
path = store / key
status, body = 200, b''
if prefix:
    root = ET.Element('ListBucketResult', xmlns='http://s3.amazonaws.com/doc/2006-03-01/')
    keys = sorted(str(p.relative_to(store)) for p in store.rglob('*')
                  if p.is_file() and str(p.relative_to(store)).startswith(prefix))
    # Two pages exercise pagination. Bad listing must never delete any key.
    if os.getenv('FAKE_BAD_LIST'): keys = ['navis/releases/current/evil.apk']
    page = keys[1:] if token else keys[:1]
    for k in page:
        entry = ET.SubElement(root, 'Contents')
        ET.SubElement(entry, 'Key').text = k
    more = len(keys) > 1 and not token
    ET.SubElement(root, 'IsTruncated').text = str(more).lower()
    if more: ET.SubElement(root, 'NextContinuationToken').text = 'next'
    body = ET.tostring(root)
elif method == 'PUT':
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(upload, path)
elif method == 'DELETE':
    path.unlink(missing_ok=True)
elif not path.exists(): status = 404
elif method == 'HEAD':
    body = f'HTTP/1.1 200 OK\r\nx-amz-meta-sha256: {hashlib.sha256(path.read_bytes()).hexdigest()}\r\n'.encode()
else:
    body = path.read_bytes()
    if os.getenv('FAKE_CHANGED_DEV') and key == 'navis/channels/dev/manifest.json' and u.hostname.endswith('.r2.cloudflarestorage.com'):
        payload = json.loads(base64.b64decode(json.loads(body)['payload']))
        if payload['tag'] == 'v1.5.0-dev.10502':
            body = Path(os.environ['FAKE_PREVIOUS']).read_bytes()
    if os.getenv('FAKE_FAIL_VERIFY') and u.hostname == 'downloads.porthorion.com' and key.endswith('.apk'):
        body = b'corrupt'
if os.getenv('FAKE_READ_ERROR') and key.startswith('navis/channels/'):
    status = 403
if method == 'HEAD' and status == 404: body = b'HTTP/1.1 404 Not Found\r\n'
if outfile: Path(outfile).write_bytes(body)
else: sys.stdout.buffer.write(body)
if write_status: print(status, end='')
if '--fail' in sys.argv or '-sSf' in sys.argv:
    if status >= 400: sys.exit(22)
PY
chmod +x "${tmp}/bin/curl"
cd "${tmp}/repo"
printf 'version: 1.5.0+10500\n' > pubspec.yaml
printf 'new apk bytes' > Navis-Dev-1.5.0-10502-arm64.apk
r2=./tool/r2_publish.sh
seed() {
  rm -rf "${FAKE_STORE}/navis"
  : > "${FAKE_LOG}"
  mkdir -p "${FAKE_STORE}/navis/channels/dev" "${FAKE_STORE}/navis/releases/v1.5.0-dev.10501"
  printf 'old apk' > "${FAKE_STORE}/navis/releases/v1.5.0-dev.10501/old.apk"
  printf 'old sums' > "${FAKE_STORE}/navis/releases/v1.5.0-dev.10501/SHA256SUMS.dev"
  sign_seed dev v1.5.0-dev.10501 10501
}
sign_seed() {
  local channel="$1" tag="$2" build="$3"
  mkdir -p "${FAKE_STORE}/navis/channels/${channel}"
  jq -cn --arg channel "${channel}" --arg tag "${tag}" --argjson build "${build}" \
    '{schema:1,channel:$channel,version:"1.5.0",tag:$tag,build:$build,assets:{androidApk:{url:("https://downloads.porthorion.com/navis/releases/"+$tag+"/old.apk"),sha256:("a"*64),size:7}}}' > "${tmp}/payload"
  openssl pkeyutl -sign -inkey "${tmp}/test.pem" -rawin -in "${tmp}/payload" -out "${tmp}/signature"
  jq -cn --arg payload "$(base64 -w0 "${tmp}/payload")" --arg signature "$(base64 -w0 "${tmp}/signature")" \
    '{payload:$payload,signature:$signature}' > "${FAKE_STORE}/navis/channels/${channel}/manifest.json"
}
refused() {
  if "$@" > "${tmp}/refused.log" 2>&1; then fail "expected refusal: $*"; fi
}
seed
FAKE_READ_ERROR=1 refused "${r2}" check --channel=dev --tag=v1.5.0-dev.10502
refused "${r2}" check --channel=dev --tag=v1.5.0 --build=10501
refused "${r2}" check --channel=stable --tag=v1.5.0-dev.10502
refused "${r2}" check --channel=dev --tag=v1.5.0-dev.10502 --build=10503
refused "${r2}" check --channel=dev --tag=v1.5.0-dev.2100000000
refused "${r2}" check --channel=dev --tag=v1.5.0-dev.10500
refused "${r2}" check --channel=dev --tag=v1.4.9-dev.99999
"${r2}" check --channel=dev --tag=v1.5.0-dev.10501 >/dev/null # idempotent retry
"${r2}" check --channel=staging --tag=v1.5.0-staging.10502 >/dev/null
"${r2}" check --channel=staging --tag=v1.5.0-dev.10502 >/dev/null
"${r2}" check --channel=stable --tag=v1.5.0 >/dev/null
"${r2}" publish --channel=dev --tag=v1.5.0-dev.10502 --prune-previous --dry-run \
  Navis-Dev-1.5.0-10502-arm64.apk > "${tmp}/plan"
for object in releases/v1.5.0-dev.10502/Navis-Dev-1.5.0-10502-arm64.apk releases/v1.5.0-dev.10502/SHA256SUMS.dev channels/dev/manifest.json; do
  rg -Fq "DRY-RUN PUT navis/${object}" "${tmp}/plan" || fail "missing PUT ${object}"
done
for object in old.apk SHA256SUMS.dev; do
  rg -Fq "DRY-RUN DELETE navis/releases/v1.5.0-dev.10501/${object}" "${tmp}/plan" || fail "missing DELETE ${object}"
done
if rg -q '^(PUT|DELETE) ' "${FAKE_LOG}"; then fail 'dry-run mutated S3'; fi
cat "${tmp}/plan"
# Exercise the real publishing code against the fake store only: verification
# failure must retain the entire previous release; success prunes just that tag.
seed
FAKE_FAIL_VERIFY=1 refused "${r2}" publish --channel=dev --tag=v1.5.0-dev.10502 --prune-previous Navis-Dev-1.5.0-10502-arm64.apk
if rg -q '^DELETE ' "${FAKE_LOG}"; then fail 'cleanup preceded verification'; fi
seed
export FAKE_PREVIOUS="${tmp}/previous-envelope"
cp "${FAKE_STORE}/navis/channels/dev/manifest.json" "${FAKE_PREVIOUS}"
FAKE_CHANGED_DEV=1 refused "${r2}" publish --channel=dev --tag=v1.5.0-dev.10502 --prune-previous Navis-Dev-1.5.0-10502-arm64.apk
if rg -q '^DELETE ' "${FAKE_LOG}"; then fail 'deleted after channel changed'; fi
seed
"${r2}" publish --channel=dev --tag=v1.5.0-dev.10502 --prune-previous Navis-Dev-1.5.0-10502-arm64.apk > "${tmp}/publish"
[[ ! -f "${FAKE_STORE}/navis/releases/v1.5.0-dev.10501/old.apk" ]] || fail 'old APK retained'
[[ ! -f "${FAKE_STORE}/navis/releases/v1.5.0-dev.10501/SHA256SUMS.dev" ]] || fail 'old sums retained'
[[ -f "${FAKE_STORE}/navis/releases/v1.5.0-dev.10502/Navis-Dev-1.5.0-10502-arm64.apk" ]] || fail 'new APK removed'
manifest_build="$(jq -r .payload "${FAKE_STORE}/navis/channels/dev/manifest.json" | base64 -d | jq -r .build)"
[[ "${manifest_build}" == 10502 ]] || fail 'signed build missing'
# Changed bytes can never replace an immutable object, even in dry-run.
printf 'different bytes' > Navis-Dev-1.5.0-10502-arm64.apk
refused "${r2}" publish --channel=dev --tag=v1.5.0-dev.10502 --dry-run Navis-Dev-1.5.0-10502-arm64.apk
seed
sign_seed staging v1.5.0-dev.10501 10501
refused "${r2}" publish --channel=dev --tag=v1.5.0-dev.10502 --prune-previous --dry-run Navis-Dev-1.5.0-10502-arm64.apk
if rg -q '^DELETE ' "${FAKE_LOG}"; then fail 'deleted a referenced object'; fi
seed
FAKE_BAD_LIST=1 refused "${r2}" publish --channel=dev --tag=v1.5.0-dev.10502 --prune-previous Navis-Dev-1.5.0-10502-arm64.apk
if rg -q '^DELETE ' "${FAKE_LOG}"; then fail 'deleted outside prefix'; fi
seed
sign_seed dev v1.5.0 10501
"${r2}" publish --channel=dev --tag=v1.5.0-dev.10502 --prune-previous --dry-run Navis-Dev-1.5.0-10502-arm64.apk > "${tmp}/shared"
rg -Fq 'Keeping previous shared tag v1.5.0' "${tmp}/shared" || fail 'shared tag not protected'
seed
jq '.signature = "invalid"' "${FAKE_STORE}/navis/channels/dev/manifest.json" > "${tmp}/forged"
cp "${tmp}/forged" "${FAKE_STORE}/navis/channels/dev/manifest.json"
refused "${r2}" check --channel=dev --tag=v1.5.0-dev.10502

# Stable publication still omits build and permits an identical retry.
seed
"${r2}" publish --channel=stable --tag=v1.5.0 --manifest-out="${tmp}/exported-manifest.json" --checksums-out="${tmp}/exported-sums" Navis-Dev-1.5.0-10502-arm64.apk > "${tmp}/stable"
cmp "${tmp}/exported-manifest.json" "${FAKE_STORE}/navis/channels/stable/manifest.json" || fail 'export differs from verified envelope'
jq -r .payload "${FAKE_STORE}/navis/channels/stable/manifest.json" | base64 -d | jq -e 'has("build") | not' >/dev/null || fail 'stable unexpectedly acquired build'
"${r2}" publish --channel=stable --tag=v1.5.0 Navis-Dev-1.5.0-10502-arm64.apk > "${tmp}/retry"
rg -Fq 'already uploaded, skipping' "${tmp}/retry" || fail 'identical retry replaced immutable bytes'
# The verify entry point compares the exact R2/GitHub bytes, using fake curl.
mkdir -p "${FAKE_STORE}/Porthorion/Navis/releases/download/v1.5.0"
cp "${FAKE_STORE}/navis/channels/stable/manifest.json" "${FAKE_STORE}/Porthorion/Navis/releases/download/v1.5.0/manifest.json"
"${r2}" verify --channel=stable --github > "${tmp}/mirror-verify"
cmp "${tmp}/exported-sums" "${FAKE_STORE}/navis/releases/v1.5.0/SHA256SUMS" || fail 'exported sums differ'
printf 'different envelope' > "${FAKE_STORE}/Porthorion/Navis/releases/download/v1.5.0/manifest.json"
refused "${r2}" verify --channel=stable --github
rg -q 'manifest bytes differ' "${tmp}/refused.log" || fail 'manifest mismatch was not detected'
# An older manifest with no build retains the semver preflight behavior.
seed
jq 'del(.build)' "${tmp}/payload" > "${tmp}/legacy-payload"
openssl pkeyutl -sign -inkey "${tmp}/test.pem" -rawin -in "${tmp}/legacy-payload" -out "${tmp}/signature"
jq -cn --arg payload "$(base64 -w0 "${tmp}/legacy-payload")" --arg signature "$(base64 -w0 "${tmp}/signature")" \
  '{payload:$payload,signature:$signature}' > "${FAKE_STORE}/navis/channels/dev/manifest.json"
"${r2}" check --channel=dev --tag=v1.5.0-dev.10502 >/dev/null

# The one-command flow, using the actual dev_app script but fake build tools.
seed
refused ./tool/dev_release.sh --dry-run
rg -Fq 'android/key.properties is required' "${tmp}/refused.log" || fail 'signing preflight missing'
mkdir -p android "${tmp}/sdk/build-tools/1"
printf 'storeFile=fake\nstorePassword=fake\nkeyAlias=fake\n' > android/key.properties
export ANDROID_SDK_ROOT="${tmp}/sdk"
cat > "${tmp}/bin/flutter" <<'SHFLUTTER'
#!/usr/bin/env bash
set -euo pipefail
[[ "${NAVIS_ALLOW_DEBUG_SIGNED_RELEASE}" == 0 && "${NAVIS_APP_ID_SUFFIX}" == .dev && "${NAVIS_APP_NAME}" == 'Navis Dev' ]]
[[ "$*" != *--obfuscate* && "$*" == *--split-debug-info=* && "$*" == *--target-platform=android-arm64* && "$*" == *--dart-define=NAVIS_UPDATE_CHANNEL=dev* ]]
for arg in "$@"; do
  case "${arg}" in --build-number=*) echo "${arg#--build-number=}" > "${FAKE_BUILD}" ;; esac
done
mkdir -p build/app/outputs/flutter-apk
printf 'fake apk' > build/app/outputs/flutter-apk/app-sideload-release.apk
SHFLUTTER
cat > "${tmp}/bin/keytool" <<'SHKEY'
#!/usr/bin/env bash
printf 'SHA256: aa:bb\n'
SHKEY
cat > "${tmp}/sdk/build-tools/1/apksigner" <<'SHSIGN'
#!/usr/bin/env bash
printf 'Signer #1 certificate SHA-256 digest: aabb\n'
SHSIGN
cat > "${tmp}/sdk/build-tools/1/aapt" <<'SHAAPT'
#!/usr/bin/env bash
printf "package: name='%s' versionCode='%s' versionName='1.5.0'\n" "${FAKE_PACKAGE:-com.navis.app.navis.dev}" "$(cat "${FAKE_BUILD}")"
SHAAPT
chmod +x "${tmp}/bin/"{flutter,keytool} "${tmp}/sdk/build-tools/1/"{aapt,apksigner}
./tool/dev_release.sh --dry-run > "${tmp}/dev-plan"
build="$(cat "${FAKE_BUILD}")"
rg -Fq "DRY-RUN PUT navis/releases/v1.5.0-dev.${build}/Navis-Dev-1.5.0-${build}-arm64.apk" "${tmp}/dev-plan" || fail 'wrong dev artifact plan'
rg -Fq "APK download URL: https://downloads.porthorion.com/navis/releases/v1.5.0-dev.${build}/Navis-Dev-1.5.0-${build}-arm64.apk" "${tmp}/dev-plan" || fail 'wrong download URL'
[[ -d "${HOME}/.cache/navis/dev-releases/v1.5.0-dev.${build}/symbols" ]] || fail 'local symbols directory missing'
if rg -q '^(PUT|DELETE) ' "${FAKE_LOG}"; then fail 'dev dry-run mutated S3'; fi
FAKE_PACKAGE=com.navis.app.navis refused ./tool/dev_release.sh --dry-run
rg -Fq 'package/version metadata' "${tmp}/refused.log" || fail 'package validation missing'
# Default dev_app APK allocations increase without touching any channel. An
# exhausted allocator must stop the script before Flutter sees an empty code.
NAVIS_ALLOW_DEBUG_SIGNED_RELEASE=0 ./tool/dev_app.sh apk --target-platform=android-arm64 --split-debug-info="${tmp}/symbols" >/dev/null
manual1="$(cat "${FAKE_BUILD}")"
NAVIS_ALLOW_DEBUG_SIGNED_RELEASE=0 ./tool/dev_app.sh apk --target-platform=android-arm64 --split-debug-info="${tmp}/symbols" >/dev/null
manual2="$(cat "${FAKE_BUILD}")"
[[ "${manual2}" -gt "${manual1}" && "${manual1}" -gt "${build}" ]] || fail 'manual dev APK counter did not increase'
printf '2099999999\n' > "${HOME}/.cache/navis/dev-releases/build-number"
NAVIS_ALLOW_DEBUG_SIGNED_RELEASE=0 refused ./tool/dev_app.sh apk
[[ "$(cat "${FAKE_BUILD}")" == "${manual2}" ]] || fail 'Flutter called after counter exhaustion'
echo 'dev_release_test: all tag, build, signed manifest, dry-run, cleanup and dev APK checks passed'
