# Navis

Navis is a Flutter-based Subsonic/OpenSubsonic music player client targeting Android and iOS.

## Project Status

- Roadmap: [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md)
- Progress tracker: [PROGRESS.md](PROGRESS.md)

## Documentation

- Development workflow: [docs/development-workflow.md](docs/development-workflow.md)
- CI/CD runbook: [docs/ci-cd.md](docs/ci-cd.md)
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

## CI/CD (Forgejo Actions)

Workflows are in `.forgejo/workflows/`:

- `ci.yml` — quality gates on `dev`, `main`, and `phase/**` with Flutter matrix (`3.32.0`, `3.41.0`)
- `maintenance.yml` — weekly dependency health (`flutter pub outdated`, `dart pub outdated`)
- `release.yml` — tag-triggered Android release APK build + artifact upload

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
