# Update channel on R2

From 1.5.0 on, Navis checks for updates at
`https://downloads.porthorion.com/navis/channels/<channel>/manifest.json` and
downloads release files from the same host. Versions before 1.5.0 read the
Forgejo releases API instead. 1.5.0 is the bridge release: it goes out through
Forgejo *and* R2, and every later release goes out through R2 only.

## Bucket layout

Cloudflare account `996fdfc369ba7a04b1fd6fef7434cd3a`, bucket `downloads`,
custom domain `downloads.porthorion.com`. The bucket is shared with other
Porthorion projects; Navis owns the `navis/` prefix.

```
navis/channels/stable/manifest.json   Cache-Control: no-cache
navis/channels/dev/manifest.json      Cache-Control: no-cache
navis/channels/staging/manifest.json  test channel; no shipped build reads it
navis/releases/<tag>/<asset>          Cache-Control: public, max-age=31536000, immutable
navis/releases/<tag>/SHA256SUMS      Cache-Control: no-cache (SHA256SUMS.<channel> off stable)
```

Release files (everything except `SHA256SUMS`) are immutable: `tool/r2_publish.sh` refuses to replace an object
whose content differs, and Cloudflare's edge keeps serving a cached copy for a
year anyway. Fix a bad release by publishing a newer version, and never delete and re-upload a
release file under the same name: clients behind a cache that still holds the old bytes
would fail the SHA-256 check for up to a year. Channels never
move to an older version.

## Manifest

The manifest file is a signed envelope:

```json
{ "payload": "<base64 of the payload JSON bytes>", "signature": "<base64 Ed25519 signature over those bytes>" }
```

The decoded payload:

```json
{
  "schema": 1,
  "channel": "stable",
  "version": "1.5.1",
  "tag": "v1.5.1",
  "published_at": "2026-11-01T12:00:00Z",
  "notes": "markdown release notes (optional)",
  "notes_url": "https://navis.porthorion.com/... (optional)",
  "assets": {
    "androidApk": { "url": "https://downloads.porthorion.com/navis/releases/v1.5.1/navis-v1.5.1.apk", "sha256": "<hex>", "size": 123 }
  }
}
```

Asset keys are the `UpdateInstallMode` names: `androidApk`, `windowsInstaller`,
`windowsPortable`, `macosBundle`, `linuxDeb-amd64`, `linuxDeb-arm64` and
`linuxPortable`. iOS has no updater, so `.ipa` files are not published.

The app accepts an update only when the signature verifies against
`AppConstants.updateSigningPublicKey`, the payload's `channel` matches its own
channel, the version is newer than the installed one, and the asset URL is
under `AppConstants.updateBaseUrl`. After downloading, it checks the file's
size and SHA-256 before installing anything. Anyone who can write to the
bucket can therefore break updates, but cannot ship a different build.

## Publishing

`tool/release.sh` builds, tags, and then calls `tool/r2_publish.sh publish`.
Before it builds anything it runs `tool/r2_publish.sh check`, which fails if
the R2 settings are missing, if the signing key does not match the key pinned
in `constants.dart`, or if the channel already holds a newer version.

- 1.5.0 only: `./tool/release.sh v1.5.0 --forgejo …` also creates the Forgejo
  release that 1.4.x installs look for.
- Later releases: `./tool/release.sh v1.5.1 …`.
- More files for the same version (the other Linux or Windows package, or the
  macOS zip built on a Mac): run `release.sh` again with `--allow-existing-version`,
  or `tool/r2_publish.sh publish` with just those files. When the channel already
  points at that tag, the new assets are added to its manifest (after checking the
  current manifest's signature) and `SHA256SUMS` is rewritten.
- Retry a failed upload: the artifacts stay in `build/` until every publish
  step succeeds, so run
  `./tool/r2_publish.sh publish --tag=v1.5.1 --channel=stable --notes-file=<md> <files…>`
  again. Files that were already uploaded are skipped.
- Check what clients see: `./tool/r2_publish.sh verify --channel=stable`. It
  checks the signature against the pinned key and downloads every asset from
  origin (bypassing the edge cache) to compare its size and SHA-256.

Uploads use the S3 API through `curl --aws-sigv4`, so no AWS CLI or rclone is
needed. The settings live in the git-ignored `tool/release.env`; see
`tool/release.env.example`.

## Signing key

Created once with:

```sh
(umask 077; openssl genpkey -algorithm ed25519 -out ~/.config/navis/update-signing-ed25519.pem)
openssl pkey -in ~/.config/navis/update-signing-ed25519.pem -pubout -outform DER | tail -c 32 | base64
```

The second command prints the value for `updateSigningPublicKey`. Keep the
private key outside the repository, with an offline backup in the password
manager. **If it is lost, installed 1.5.0+ builds can no longer be updated**;
users would have to reinstall a build with a new pinned key by hand. If it
leaks, ship a release (signed with the old key) that pins a new key, then
retire the old one.

## Testing a channel without users

Shipped builds only read `stable` or `dev`. To test end to end, build with
`--dart-define=NAVIS_UPDATE_CHANNEL=staging`, publish a newer version to
`staging` with `tool/r2_publish.sh publish --channel=staging …`, and use the
diagnostics routes `GET /v1/diagnostics/update`,
`POST /v1/diagnostics/update/check` and `POST /v1/diagnostics/update/download`
(download plus size and SHA-256 check, no install) to see what the app decided.
`tool/r2_update_diagnostics.sh` automates this on Linux: it launches a profile clone on
`staging`, then checks a missing manifest, a signed offer, a verified download, a corrupt
asset, a forged manifest, and a full apply, swap and relaunch.
`tool/r2_update_diagnostics_android.sh` builds a `.r2test` profile sideload APK and runs the
same offer, download, corrupt and forged checks on a booted emulator (installing the APK
needs the system prompt, so it stops before install). Delete the
staging objects afterwards.

## Forgejo during the transition

1.4.x installs keep polling
`https://git.porthorion.com/api/v1/repos/khalifa/Navis/releases` and download
1.5.0 from there. That endpoint and the 1.5.0 asset downloads must stay
readable without signing in until 1.4.x installs are gone. Before making the
repository private, move the releases to a public releases-only repository at
the same path, or serve compatible JSON from a proxy.
