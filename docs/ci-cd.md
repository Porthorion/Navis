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

## Release (`tool/release.sh`)

Builds a release APK, tags the commit, creates a Forgejo release, and uploads the APK — all from the local machine.

### Setup (one-time)

1. Install `jq`:
   ```bash
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
./tool/release.sh v0.2.0          # stable release
./tool/release.sh v0.3.0-beta.1   # pre-release (auto-detected from tag)
```

Or via Makefile:
```bash
make release VERSION=v0.2.0
```

### What it does

1. Runs `./tool/check.sh` (format, analyze, lint, tests). Fails fast on any issue.
2. Builds release APK: `flutter build apk --release`.
3. Creates an annotated git tag and pushes it.
4. Determines release type: tags containing `-alpha`, `-beta`, `-rc`, or `-dev` → pre-release; clean semver tags → stable.
5. Creates a Forgejo release via the API.
6. Uploads the APK as a release asset.

### Required environment variables

| Variable | Description |
|---|---|
| `FORGEJO_URL` | Forgejo instance URL (e.g. `https://forgejo.example.com`) |
| `FORGEJO_REPO` | Repository path (e.g. `user/Navis`) |
| `FORGEJO_TOKEN` | API token with release write access |

Set these in `tool/release.env` or export them in your shell.

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

