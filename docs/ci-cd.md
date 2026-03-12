# Quality Gates & Releases

All quality gates and release publishing run locally. There is no CI runner — `tool/check.sh` and `tool/release.sh` replace what Forgejo Actions workflows would do.

## Quality Gate (`tool/check.sh`)

Run before every commit (automatically enforced if the pre-commit hook is enabled):

```bash
./tool/check.sh
```

Checks performed (in order, fail-fast):
1. `dart format --set-exit-if-changed .`
2. `dart run build_runner build --delete-conflicting-outputs`
3. `flutter analyze`
4. `dart run custom_lint`
5. `flutter test`

The script also checks `/tmp` disk space before starting to prevent misleading test hangs.

### Core Gate (No custom_lint dependency)

Use when `custom_lint` is unavailable on the release host:

```bash
./tool/release_gate_core.sh
./tool/release_gate_core.sh --quick
```

## Release (`tool/release.sh`)

Builds selected release artifacts, tags the commit, creates a Forgejo release, and uploads all assets — all from the local machine.

### Setup (one-time)

1. Install `jq`:
   ```bash
   # macOS
   brew install jq
   # Linux
   sudo apt install jq
   ```

2. Create `tool/release.env` with your Forgejo credentials (this file is git-ignored):
   ```bash
   FORGEJO_URL="https://your-forgejo-instance.com"
   FORGEJO_REPO="your-user/Navis"
   FORGEJO_TOKEN="your-api-token"
   ```

3. Ensure the script is executable:
   ```bash
   chmod +x tool/release.sh
   ```

### Usage

```bash
./tool/release.sh v0.2.0
./tool/release.sh v0.2.0 --channel=dev
./tool/release.sh v0.2.0 --targets=android,macos
./tool/release.sh v0.2.0 --all-platforms
./tool/release.sh v0.2.0 --targets=linux --linux-package=deb
./tool/release.sh v0.2.0 --targets=windows --windows-package=exe
./tool/release.sh v0.2.0 --targets=macos --macos-notarize
./tool/release.sh v0.2.0 --targets=linux,windows --linux-ssh="linux-builder" --windows-ssh="windows-builder"
```

Or via Makefile:
```bash
make release VERSION=v0.2.0
```

### What it does

1. Runs `./tool/check.sh` (format, analyze, lint, tests) unless `--skip-checks` is passed.
2. Builds selected artifacts for requested targets (`android`, `ios`, `macos`, `linux`, `windows`).
2.1 For Linux target, can output either portable `bundle` (tar.gz) or `.deb` (`--linux-package=deb`).
2.2 Debian package output is architecture-aware (`linux-<arch>.deb`) and includes a launcher binary and desktop entry.
2.3 For Windows target, can output `.zip` (default) or Inno Setup `.exe` installer (`--windows-package=exe`).
2.4 For macOS target, can optionally sign + notarize + staple before packaging (`--macos-notarize`).
2.5 On non-Linux/non-Windows hosts, Linux/Windows desktop builds can be delegated to remote SSH builders (`--linux-ssh`, `--windows-ssh`).
3. Passes `--dart-define=NAVIS_UPDATE_CHANNEL=<stable|dev>` to Flutter builds.
4. For `--channel=dev`, defaults Android sidecar identity to `.dev` / `Navis Dev`.
5. Creates an annotated git tag and pushes main/current branch/tag.
6. Creates a Forgejo release with `prerelease=true` for dev channel (or when `--prerelease` is passed).
7. Uploads all built assets to the release.

### Release channels

- `stable` channel assets are named `navis-<tag>.*`
- `dev` channel assets are named `navis-dev-<tag>.*`

The app updater uses `NAVIS_UPDATE_CHANNEL` to prefer channel-matching assets.

### Required environment variables

| Variable | Description |
|---|---|
| `FORGEJO_URL` | Forgejo instance URL (e.g. `https://forgejo.example.com`) |
| `FORGEJO_REPO` | Repository path (e.g. `user/Navis`) |
| `FORGEJO_TOKEN` | API token with release write access |

Optional variables:

| Variable | Description |
|---|---|
| `NAVIS_DEB_MAINTAINER` | Maintainer string for Linux Debian package metadata |
| `MACOS_SIGN_IDENTITY` | Developer ID Application signing identity used by `--macos-notarize` |
| `MACOS_NOTARY_PROFILE` | `xcrun notarytool` keychain profile name used by `--macos-notarize` |
| `NAVIS_LINUX_SSH` | Default SSH target for remote Linux builder |
| `NAVIS_WINDOWS_SSH` | Default SSH target for remote Windows builder |
| `NAVIS_LINUX_REMOTE_DIR` | Remote Linux working dir relative to remote HOME |
| `NAVIS_WINDOWS_REMOTE_DIR` | Remote Windows working dir relative to remote HOME |

Set these in `tool/release.env` or export them in your shell.

### Additional packaging prerequisites

- Windows installer mode (`--windows-package=exe`)
  - Requires Inno Setup 6 (`ISCC.exe`) on the Windows build host.
  - Install from https://jrsoftware.org/isdl.php and ensure `ISCC.exe` is on `PATH`.
- macOS notarization mode (`--macos-notarize`)
  - Requires a valid Developer ID Application certificate in keychain.
  - Requires a configured `notarytool` keychain profile:
    ```bash
    xcrun notarytool store-credentials navis-notary-profile \
      --apple-id "<apple-id>" \
      --team-id "<team-id>" \
      --password "<app-specific-password>"
    ```

Credential governance and secure handling reference:
`docs/release-secrets.md`

Remote desktop build architecture and setup:
`docs/multi-os-build-from-mac.md`

## Dependency Health (manual)

Run periodically to check for outdated packages:

```bash
flutter pub outdated
dart pub outdated
```

Or via Makefile:
```bash
make outdated
```

## Release Workflow Summary

The intended flow for shipping a feature or fix:

1. Work on `dev` branch (or a `phase/` branch merged into `dev`).
2. Run `./tool/check.sh` — all checks pass.
3. Commit with Conventional Commits format.
4. When ready to release: merge `dev` → `main`.
5. Run `./tool/release.sh v0.x.0` from `main`.
6. The script handles everything: checks, build, tag, Forgejo release, APK upload.
