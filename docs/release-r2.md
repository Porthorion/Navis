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
move to an older version, or to an older build at the same version on dev/staging.

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
  "build": 10501,
  "tag": "v1.5.1",
  "published_at": "2026-11-01T12:00:00Z",
  "notes": "markdown release notes (optional)",
  "notes_url": "https://navis.porthorion.com/... (optional)",
  "assets": {
    "androidApk": { "url": "https://downloads.porthorion.com/navis/releases/v1.5.1/navis-v1.5.1.apk", "sha256": "<hex>", "size": 123 }
  }
}
```

Asset keys are based on the `UpdateInstallMode` names: `androidApk`,
`androidApk-arm64-v8a`, `androidApk-armeabi-v7a`, `androidApk-x86_64`,
`windowsInstaller`, `windowsPortable`, `macosBundle`, `linuxDeb-amd64`,
`linuxDeb-arm64` and `linuxPortable`. `linuxRpm-x86_64` is available for
download consumers; RPM uses manual package-manager updates, not a new
`UpdateInstallMode`. See [release-linux.md](release-linux.md). iOS has no
updater, so `.ipa` files are not published. Additional asset keys do not change
schema 1; clients ignore keys they do not select.

`build` is an optional integer in the signed payload. Stable compares only
semver. Dev and staging also accept an equal semver when `build` is greater
than the installed `PackageInfo.buildNumber`. A lower semver is never offered,
even with a higher build. Missing `build` retains semver-only behavior; malformed
build values are rejected. The schema stays at 1, so older manifests work.

The app accepts an update only when the signature verifies against
`AppConstants.updateSigningPublicKey`, the payload's `channel` matches its own
channel, the version/build is newer under those rules, and the asset URL is
under `AppConstants.updateBaseUrl`. After downloading, it checks the file's
size and SHA-256 before installing anything. Anyone who can write to the
bucket can therefore break updates, but cannot ship a different build.

### Android APKs

Starting with 1.5.0, `tool/release.sh <tag> --targets=android` produces all four APKs:

| Asset | Manifest key | Purpose |
|---|---|---|
| `navis-<tag>.apk` | `androidApk` | Universal, default manual download and fallback |
| `navis-<tag>-android-arm64-v8a.apk` | `androidApk-arm64-v8a` | ARM 64-bit |
| `navis-<tag>-android-armeabi-v7a.apk` | `androidApk-armeabi-v7a` | ARM 32-bit |
| `navis-<tag>-android-x86_64.apk` | `androidApk-x86_64` | x86 64-bit |

Flutter does not build a 32-bit x86 APK. Keep the universal filename exactly
`navis-<tag>.apk`: 1.4.x Forgejo clients look for it during the 1.5.0 bridge
release. Dev-channel `release.sh` builds use the `navis-dev` prefix.
The 1.5.0+ updater reads `Build.SUPPORTED_ABIS[0]` through the existing Android
distribution channel and prefers the corresponding split asset. Missing split
assets, unknown ABIs and unavailable device metadata fall back to `androidApk`.
The chosen asset still requires the signed URL, size and SHA-256 checks.

`android/gradle.properties` sets `force-version-code-ignoring-abi=true`.
Flutter's Gradle plugin reads this property and skips its usual split APK
`abiVersionCode * 1000 + versionCode` override. Universal and split APKs
therefore share the release build number (10500 for 1.5.0), allowing updates
between them without an ABI offset causing a downgrade. Every APK must pass
package, version name/code, release-certificate, secret-scan and release-string
validation before publication.

The universal APK is copied outside `build/app` before the split build cleans
its outputs. Both builds use the same sideload flavor, obfuscation and Dart
defines; their symbols remain separate under
`build/obfuscation/android/<tag>/universal/` and
`build/obfuscation/android/<tag>/split-per-abi/`.

## Publishing

`tool/release.sh` builds, tags, and then calls `tool/r2_publish.sh publish`.
Before it builds anything it runs `tool/r2_publish.sh check`, which fails if
the R2 settings are missing, if the signing key does not match the key pinned
in `constants.dart`, or if the channel already holds a newer version.

For a two-phase release, `release.sh <tag> --build-only` instead stages the
validated selected assets and checksums under `dist/<tag>/`, without R2
checks or Git/release publication. `release.sh <tag> --publish-from=dist/<tag>`
verifies the staged files and source commit, repeats the normal remote
preconditions, and runs the same Git and R2 publication flow without rebuilding.
The channel, prerelease state and notes come from the bundle; `--forgejo` is
still required on release day for the 1.5.0 bridge. The dist files are retained.
See [release-from-linux.md](release-from-linux.md#build-and-verify-150-now-publish-those-files-later)
for the exact 1.5.0 build, verify and publish commands.

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

## Navis Dev APK releases

From the Linux coordinator with Android release signing configured and the R2
settings in `tool/release.env`, run:

```sh
./tool/dev_release.sh --dry-run
./tool/dev_release.sh
```

Both commands build an arm64, release-signed `.dev` sidecar through
`dev_app.sh apk`, with `NAVIS_UPDATE_CHANNEL=dev`, Dart obfuscation and split
debug info. Dry-run does the local build, validates the APK package/version and
release certificate, signs the planned manifest, and performs read-only R2
checks. It prints `DRY-RUN PUT`, `DRY-RUN VERIFY` and `DRY-RUN DELETE` operations;
it does not upload or delete. The final line prints the APK download URL.
Release signing is required even in dry-run; debug signing is refused.

The version name remains the semver from `pubspec.yaml`. `dev_build_number.py`
allocates `max(10,500,000 + seconds since 2026-01-01 00:00:00 UTC, previous + 1)`.
The locked counter at `~/.cache/navis/dev-releases/build-number` is shared across
worktrees. It prevents collisions for repeated builds in the same second and
keeps numbers increasing across days and clock rollback. Numbers must exceed
10500 and remain below Android's 2,100,000,000 limit; exhaustion fails before
building. Manual `dev_app.sh apk` builds use the same allocator unless an explicit
Flutter `--build-number` is supplied. Dry-runs and failed builds consume numbers.
Keep the counter; gaps are harmless. Use one coordinator for publishing: its
`release.lock` serializes the complete dev build/publish/cleanup, while the R2
preflight rejects stale builds from other machines. The lock is local, so do not
run competing publishers on other hosts.

Each build uses `v<version>-dev.<build>` as its R2 tag and
`Navis-Dev-<version>-<build>-arm64.apk` as its immutable asset name. No Git tag or
pubspec change is made. Symbols stay under
`~/.cache/navis/dev-releases/<tag>/symbols`; the APK stays in `build/dev-releases/`.
`r2_publish.sh` infers the signed `build` from the unique tag, or accepts
`--build=<int>` (which must agree with the tag). Dev and staging accept
`v<version>-dev.<build>` and `v<version>-staging.<build>`; stable tags stay strictly
`vX.Y.Z`. Staging can therefore test the same dev tag; any live staging reference
protects that tag from dev cleanup.

After the new manifest and every asset verify, `--prune-previous` lists all
objects under the previous unique dev tag using the existing curl SigV4 S3
helper and deletes only that namespace, including `SHA256SUMS.dev`. Before
cleanup it authenticates the live stable/dev/staging manifests and refuses
cleanup if any still points at that tag or one of its objects, or if dev no
longer points at the new tag. Pagination and namespace validation are checked
before deletion starts. A prior plain/shared tag such as `v1.5.0` is kept to
protect stable assets. The normal unique-tag flow retains only the current dev
build. Failed verification leaves the previous release untouched and returns an
error; a cleanup failure returns an error and may leave some previous objects.
If cleanup fails after publication, the coordinator must resolve the
reported condition before cleaning the leftover namespace; a subsequent build
only knows its immediate predecessor. Never remove an object referenced by a
live manifest. Builds installed before this equal-version comparison change
need this updated sidecar installed once manually.

The plan can also be checked for an already-built APK, without rebuilding:

```sh
./tool/r2_publish.sh publish --channel=dev --tag=v1.5.0-dev.10500001 \
  --prune-previous --dry-run build/dev-releases/Navis-Dev-1.5.0-10500001-arm64.apk
```

Run `./tool/dev_release_test.sh` for hermetic tag, counter, signed manifest,
immutable asset, dry-run, verification-before-cleanup, referenced-object and APK
validation coverage. It uses disposable keys, fake Flutter/Android tools and a
local fake S3 store. `tool/check.sh` includes this shell test.

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
