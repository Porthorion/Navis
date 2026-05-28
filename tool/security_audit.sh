#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

echo "==> Secret and token scan"
rg -n --hidden \
  --glob '!.git/**' \
  --glob '!build/**' \
  --glob '!.dart_tool/**' \
  --glob '!**/*.g.dart' \
  --glob '!lib/l10n/app_localizations*.dart' \
  --glob '!pubspec.lock' \
  --glob '!tool/security_audit.sh' \
  --glob '!tool/release.env' \
  --glob '!tool/secrets/**' \
  '(api[_-]?key[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9._-]{16,}|shared[_-]?secret[[:space:]]*[:=]|bearer[[:space:]]+[A-Za-z0-9._-]{16,}|password[[:space:]]*[=:][[:space:]]*["'\''][^"'\'']{8,}|private[_-]?key[[:space:]]*[:=]|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|keystore[[:space:]]*[:=])' \
  . || true

echo "==> Tracked env files"
git ls-files | rg '(^|/)(\.env($|\.)|release\.env$)' || true

echo "==> Android Play build blockers"
if rg -n 'REQUEST_INSTALL_PACKAGES|installApk|ACTION_INSTALL_PACKAGE|FileProvider' android lib; then
  echo "Play blocker found: APK self-install path is still present." >&2
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
