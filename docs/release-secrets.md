# Release Secrets & Credential Flow

This document defines the recommended secret handling model for Navis multi-OS releases.

## Goals

- Keep signing and API credentials out of git.
- Support local release automation (`tool/release.sh`) without hardcoding secrets.
- Keep credential setup reproducible across release operators.

## Secret classes

1. Forgejo release API token
2. Android signing keystore and passwords
3. Apple signing identity + notarization credentials
4. Optional Linux package metadata (maintainer identity)

## Storage policy

- Never commit secrets to the repository.
- Use local-only files and system keychains:
  - `tool/release.env` (already git-ignored)
  - macOS Keychain for Apple notarytool profile
  - local `android/key.properties` and keystore files (never committed)

## Forgejo token

Put token in local `tool/release.env`:

```bash
FORGEJO_URL="https://git.porthorion.com"
FORGEJO_REPO="khalifa/Navis"
FORGEJO_TOKEN="<token-with-release-write-scope>"
```

Rotation guidance:
- rotate after personnel/device changes
- rotate immediately if suspected exposure

## Android signing

Required local files:
- `android/key.properties`
- referenced keystore path from `storeFile=...`

Keep keystore + passwords in password manager and only provision on trusted release hosts.

## macOS notarization

Set signing identity in shell or local env file:

```bash
export MACOS_SIGN_IDENTITY="Developer ID Application: <Team Name> (<TEAMID>)"
```

Store notarization credentials in keychain once:

```bash
xcrun notarytool store-credentials navis-notary-profile \
  --apple-id "<apple-id>" \
  --team-id "<team-id>" \
  --password "<app-specific-password>"
```

Then export:

```bash
export MACOS_NOTARY_PROFILE="navis-notary-profile"
```

## Recommended release-host checklist

- dedicated trusted machine for release operations
- full-disk encryption enabled
- screen lock and account password required
- no plaintext secret files outside intended local config paths
- periodic token/password rotation

## Preflight before release

```bash
./tool/multi_os_host_preflight.sh --doctor
./tool/release_gate_core.sh
```

Then release as needed:

```bash
./tool/release.sh v0.x.y --targets=android,macos
./tool/release.sh v0.x.y --targets=macos --macos-notarize
```
