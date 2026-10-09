# Release Secrets & Credential Flow

This document defines the recommended secret handling model for Navis multi-OS releases.

## Goals

- Keep signing and API credentials out of git.
- Support local release automation (`tool/release.sh`) without hardcoding secrets.
- Keep credential setup reproducible across release operators.

## Secret classes

1. Update signing key and R2 API keys (every release)
2. Forgejo release API token (only for `--forgejo`, the 1.5.0 bridge release)
3. Android signing keystore and passwords
4. Google Play service account JSON for AAB upload automation
5. Apple signing identity + notarization credentials
6. Optional Linux package metadata (maintainer identity)
7. Last.fm API key bundled into release builds

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

## Update signing key and R2 keys

Every release publishes to Cloudflare R2 with a signed update manifest; see
[release-r2.md](release-r2.md) for the full procedure.

- `NAVIS_UPDATE_SIGNING_KEY` in `tool/release.env` is the path to an Ed25519 PEM
  private key (default `~/.config/navis/update-signing-ed25519.pem`, mode 600). Its
  public half is pinned in `lib/src/utils/constants.dart` as `updateSigningPublicKey`;
  `tool/r2_publish.sh` refuses to sign with any other key. Keep the PEM outside the
  repository and never commit it.
- Back it up offline in the password manager. If it is lost, installed 1.5.0+ builds
  can no longer be updated automatically and users must reinstall a build that pins a
  new key.
- Rotation: if it leaks, ship a release signed with the old key that pins a new public
  key, then retire the old key. Do not rotate casually, since each installed build only
  trusts the key it shipped with.
- `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_PREFIX`, `R2_ACCESS_KEY_ID` and
  `R2_SECRET_ACCESS_KEY` live in `tool/release.env`. Create the access key as an R2 API
  token with Object Read & Write limited to the `downloads` bucket, and rotate it after
  device or personnel changes or suspected exposure. It cannot ship a different build
  on its own, because clients also check the manifest signature and each download's
  SHA-256, but it can break updates.
- `NAVIS_RELEASE_NOTES_URL` (optional) is public and not a secret.

## Forgejo token

Needed only for `release.sh --forgejo`. Put the token in local `tool/release.env`:

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
- `tool/release.env`, `android/key.properties` and the keystores are mode 600
  (`tool/security_audit.sh` fails otherwise)
- remote builders receive only tracked files (`git ls-files`), never these
  secrets; their sshd allows key logins from the LAN only
- obfuscation symbols under `build/obfuscation/<platform>/<version>` stay on the
  release host and are never uploaded
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
