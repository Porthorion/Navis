#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

echo "==> Secret and token scan"
if rg -n --hidden \
  --glob '!.git/**' \
  --glob '!build/**' \
  --glob '!.dart_tool/**' \
  --glob '!**/*.g.dart' \
  --glob '!lib/l10n/app_localizations*.dart' \
  --glob '!pubspec.lock' \
  --glob '!tool/security_audit.sh' \
  --glob '!tool/release.env' \
  --glob '!test/**' \
  --glob '!android/key.properties.example' \
  '(^[[:space:]]*(storePassword|keyPassword)=[^[:space:]]+|api[_-]?key[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9._-]{16,}|shared[_-]?secret[[:space:]]*[:=]|bearer[[:space:]]+[A-Za-z0-9._-]{16,}|password[[:space:]]*[=:][[:space:]]*["'\''][^"'\'']{8,}|private[_-]?key[[:space:]]*[:=]|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|keystore[[:space:]]*[:=])' \
  .; then
  echo "Secret-like values found above; remove them or extend the exclusions." >&2
  exit 1
fi

echo "==> Tracked env files"
if git ls-files | rg '(^|/)(\.env($|\.)|release\.env$)'; then
  echo "Env files must not be tracked." >&2
  exit 1
fi

echo "==> Local secret file permissions"
for secret in tool/release.env android/key.properties android/*.jks android/app/*.jks; do
  [[ -f "${secret}" ]] || continue
  mode="$(stat -c '%a' "${secret}" 2>/dev/null || stat -f '%Lp' "${secret}")"
  if [[ "${mode}" != "600" && "${mode}" != "400" ]]; then
    echo "${secret} is mode ${mode}; run chmod 600 on it." >&2
    exit 1
  fi
done

echo "==> Android Play manifest blockers"
if rg -n 'REQUEST_INSTALL_PACKAGES|FileProvider' android/app/src/main/AndroidManifest.xml; then
  echo "Play blocker found: base Android manifest must not declare APK self-install permissions." >&2
  exit 1
fi

echo "==> Play release self-update guard"
if ! rg -n 'NAVIS_SELF_UPDATE=false' tool/play_release.sh >/dev/null; then
  echo "Play blocker found: tool/play_release.sh must disable NAVIS_SELF_UPDATE." >&2
  exit 1
fi

echo "==> Sideload APK self-update guard"
if ! rg -n 'NAVIS_SELF_UPDATE=true' tool/release.sh >/dev/null; then
  echo "Forgejo release blocker found: tool/release.sh must enable NAVIS_SELF_UPDATE for Android APK builds." >&2
  exit 1
fi

echo "==> Update channel pin"
if ! rg -n "updateBaseUrl = 'https://downloads\.porthorion\.com/navis/'" lib/src/utils/constants.dart >/dev/null; then
  echo "Update blocker found: AppConstants.updateBaseUrl must pin https://downloads.porthorion.com/navis/." >&2
  exit 1
fi

echo "==> Public repository links in app UI"
if rg -n 'aboutSourceCode|Source code|View on Forgejo' lib/src/features lib/l10n; then
  echo "Review public app links above and ensure they are hidden in Play builds." >&2
fi

if command -v gitleaks >/dev/null 2>&1; then
  echo "==> gitleaks"
  gitleaks detect --source . --redact
else
  echo "==> gitleaks not installed; skipping optional scan"
fi

echo "==> Security audit completed"
