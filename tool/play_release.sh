#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PLAY_TRACK="internal"
PLAY_STATUS="draft"
PLAY_USER_FRACTION=""
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
    --play-track=*) PLAY_TRACK="${arg#--play-track=}" ;;
    --play-status=*) PLAY_STATUS="${arg#--play-status=}" ;;
    --play-user-fraction=*) PLAY_USER_FRACTION="${arg#--play-user-fraction=}" ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      cat <<'USAGE'
Usage: tool/play_release.sh [--dry-run] [--play-track=internal|closed|open|production] [--play-status=draft|completed|inProgress] [--play-user-fraction=0.05]

Builds a signed Android App Bundle and uploads it to Google Play.
Requires tool/release.env with PLAY_SERVICE_ACCOUNT_JSON.

Track aliases:
  closed -> alpha
  open   -> beta
USAGE
      exit 0
      ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

case "${PLAY_TRACK}" in
  internal) PLAY_API_TRACK="internal" ;;
  closed) PLAY_API_TRACK="alpha" ;;
  open) PLAY_API_TRACK="beta" ;;
  production) PLAY_API_TRACK="production" ;;
  *) echo "Unsupported --play-track: ${PLAY_TRACK}" >&2; exit 2 ;;
esac

case "${PLAY_STATUS}" in
  draft|completed) ;;
  inProgress)
    if [[ -z "${PLAY_USER_FRACTION}" ]]; then
      echo "--play-status=inProgress requires --play-user-fraction, for example 0.05." >&2
      exit 2
    fi
    ;;
  *) echo "Unsupported --play-status: ${PLAY_STATUS}" >&2; exit 2 ;;
esac

if [[ -f tool/release.env ]]; then
  # shellcheck disable=SC1091
  source tool/release.env
fi

PACKAGE_NAME="${PLAY_PACKAGE_NAME:-com.navis.app.navis}"
SERVICE_ACCOUNT_JSON="${PLAY_SERVICE_ACCOUNT_JSON:-}"

echo "==> Building release Android App Bundle"
export NAVIS_SELF_UPDATE=false
flutter build appbundle --release --dart-define=NAVIS_SELF_UPDATE=false
AAB_PATH="build/app/outputs/bundle/release/app-release.aab"
if [[ ! -f "${AAB_PATH}" ]]; then
  echo "AAB not found at ${AAB_PATH}" >&2
  exit 1
fi

if [[ "${DRY_RUN}" == true ]]; then
  echo "Dry run complete: built ${AAB_PATH}; no Play edit was created."
  exit 0
fi

if [[ -z "${SERVICE_ACCOUNT_JSON}" || ! -f "${SERVICE_ACCOUNT_JSON}" ]]; then
  echo "PLAY_SERVICE_ACCOUNT_JSON must point to a Google Play service-account JSON file." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

python3 - "${SERVICE_ACCOUNT_JSON}" "${tmpdir}" <<'PY'
import base64
import json
import sys
from pathlib import Path

service_account = json.loads(Path(sys.argv[1]).read_text())
tmpdir = Path(sys.argv[2])
header = {"alg": "RS256", "typ": "JWT"}
now = __import__("time").time()
claims = {
    "iss": service_account["client_email"],
    "scope": "https://www.googleapis.com/auth/androidpublisher",
    "aud": "https://oauth2.googleapis.com/token",
    "iat": int(now),
    "exp": int(now) + 3600,
}
def b64url(data):
    raw = json.dumps(data, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
signing_input = f"{b64url(header)}.{b64url(claims)}"
(tmpdir / "signing_input").write_text(signing_input)
(tmpdir / "private_key.pem").write_text(service_account["private_key"])
PY

openssl dgst -sha256 -sign "${tmpdir}/private_key.pem" -out "${tmpdir}/sig" "${tmpdir}/signing_input"
signature="$(python3 - "${tmpdir}/sig" <<'PY'
import base64, sys
print(base64.urlsafe_b64encode(open(sys.argv[1], "rb").read()).rstrip(b"=").decode())
PY
)"
jwt="$(cat "${tmpdir}/signing_input").${signature}"

access_token="$(curl -fsS https://oauth2.googleapis.com/token \
  -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  -d assertion="${jwt}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

api="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE_NAME}"
echo "==> Creating Play edit"
edit_id="$(curl -fsS -X POST "${api}/edits" \
  -H "Authorization: Bearer ${access_token}" \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

echo "==> Uploading AAB to ${PLAY_TRACK}/${PLAY_API_TRACK} (${PLAY_STATUS})"
version_code="$(curl -fsS -X POST "${api}/edits/${edit_id}/bundles?uploadType=media" \
  -H "Authorization: Bearer ${access_token}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"${AAB_PATH}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["versionCode"])')"

if [[ -n "${PLAY_USER_FRACTION}" ]]; then
  user_fraction_json=",
      \"userFraction\": ${PLAY_USER_FRACTION}"
else
  user_fraction_json=""
fi

cat > "${tmpdir}/track.json" <<JSON
{
  "track": "${PLAY_API_TRACK}",
  "releases": [
    {
      "status": "${PLAY_STATUS}",
      "versionCodes": ["${version_code}"]${user_fraction_json}
    }
  ]
}
JSON

curl -fsS -X PUT "${api}/edits/${edit_id}/tracks/${PLAY_API_TRACK}" \
  -H "Authorization: Bearer ${access_token}" \
  -H "Content-Type: application/json" \
  -d @"${tmpdir}/track.json" >/dev/null

echo "==> Committing Play edit"
curl -fsS -X POST "${api}/edits/${edit_id}:commit" \
  -H "Authorization: Bearer ${access_token}" >/dev/null

echo "Uploaded versionCode ${version_code} to ${PLAY_TRACK}/${PLAY_API_TRACK} as ${PLAY_STATUS}"
