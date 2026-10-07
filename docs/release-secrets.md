# Release Secrets & Credential Flow

This document defines the recommended secret handling model for Navis multi-OS releases.

## Goals

- Keep signing and API credentials out of git.
- Support local release automation (`tool/release.sh`) without hardcoding secrets.
- Keep credential setup reproducible across release operators.

## Secret classes

1. Forgejo release API token
2. Android signing keystore and passwords
3. Google Play service account JSON for AAB upload automation
4. Apple signing identity + notarization credentials
5. Optional Linux package metadata (maintainer identity)
6. Last.fm API key bundled into release builds

## Storage policy

- Never commit secrets to the repository.
- Use local-only files and system keychains:
  - `tool/release.env` (already git-ignored)
  - macOS Keychain for Apple notarytool profile
  - local `android/key.properties` and keystore files (never committed)
- The ListenBrainz token is a runtime user credential. It must stay in
  platform secure storage, not Drift or logs. (Last.fm shared secrets and
  session keys no longer exist; Last.fm scrobbling was removed.)
- The bundled Last.fm API key lives in `tool/release.env` as
  `NAVIS_LASTFM_API_KEY` and is covered below.

## Last.fm API key

Put the key in local `tool/release.env`:

```bash
NAVIS_LASTFM_API_KEY="<lastfm-api-key>"
```

Required for Android and Google Play builds; bundled in every target when set.
Builds bundle it masked, not in plaintext: a fresh random pad per build, with
`NAVIS_LASTFM_API_KEY_MASKED` (key XOR pad) and `NAVIS_LASTFM_API_KEY_PAD`
handed to Flutter through a mode-600 `--dart-define-from-file` (so they are not on the scripts' own command lines; Flutter may forward them to its child processes) that is deleted
when the script exits. Remote builders receive that file over ssh stdin (Linux)
or scp (Windows), not on the scripts' own command lines, and delete it after the build.
`tool/release.sh` and `tool/play_release.sh` then scan every artifact for the
plaintext key and fail the release if it appears.

State this plainly when discussing it: masking deters casual extraction and is
not secrecy. The app must hold the key to call Last.fm, and a Last.fm API key is
a client identifier, not a credential; no shared secret is used. Rotate the key
if it is posted publicly, but do not treat a bundled key as confidential.

Never paste the key into issues, logs, commit messages or chat, and never
commit `tool/release.env`.

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
`tool/release.sh` refuses Android publication without `android/key.properties`.
Gradle also rejects release builds without it; the
`NAVIS_ALLOW_DEBUG_SIGNED_RELEASE=1` escape hatch is for local development only
and does not bypass publication checks. Debug/profile signing is unaffected.

For Google Play continuity, the initial Play App Signing setup must use the
existing release signing key as the app signing key. If a separate upload key is
introduced later, keep it outside git and rotate it independently from the app
signing key.

## Google Play service account

Put only the local path in `tool/release.env`:

```bash
PLAY_SERVICE_ACCOUNT_JSON="/absolute/path/google-play-service-account.json"
PLAY_PACKAGE_NAME="com.navis.app.navis"
```

Use `tool/play_release.sh --dry-run` before creating a Play edit. Service
account JSON files must never be copied into the repository.

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
