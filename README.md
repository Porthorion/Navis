# Navis

Navis is a Flutter-based Subsonic/OpenSubsonic music player client targeting Android and iOS.

## Project Status

- Roadmap: [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md)
- Progress tracker: [PROGRESS.md](PROGRESS.md)

## Documentation

- Development workflow: [docs/development-workflow.md](docs/development-workflow.md)
- Release & quality gates: [docs/ci-cd.md](docs/ci-cd.md)
- Troubleshooting: [docs/troubleshooting.md](docs/troubleshooting.md)

## Bootstrap

```bash
./tool/bootstrap.sh
./tool/check.sh
```

## Local Guardrails (Optional)

Enable the repository pre-commit hook:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

This will run `./tool/check.sh` before each commit.

## Quality Gate

Run before each commit:

```bash
./tool/check.sh
```

This checks formatting, code generation, static analysis, linting, and tests.

## Phase 1 Close-Out

Run the dedicated close-out gate when finalizing Phase 1:

```bash
export NAVIS_SMOKE_BASE_URL="https://your-subsonic-host"
export NAVIS_SMOKE_USERNAME="your-username"
export NAVIS_SMOKE_PASSWORD="your-password"
# Optional (defaults shown):
export NAVIS_SMOKE_API_VERSION="1.16.1"
export NAVIS_SMOKE_USE_LEGACY_AUTH="false"

./tool/phase1_closeout.sh
# or: make phase1-closeout
```

This command verifies drift DB tests are not skipped and runs a real-server
`ping()` + capabilities smoke check.

## Release

Publish a versioned release with APK to Forgejo:

```bash
./tool/release.sh v0.2.0
```

See [docs/ci-cd.md](docs/ci-cd.md) for setup and details.

## Run

```bash
flutter run
```

## Troubleshooting

- If tests appear stuck, verify disk headroom first:

```bash
df -h /tmp
```

`./tool/check.sh` now fails fast when `/tmp` is critically low.
