# CI/CD

Forgejo Actions workflows are under `.forgejo/workflows`.

## CI (`ci.yml`)

Triggered on pushes to `dev`, `main`, `phase/**`, and pull requests into `dev`/`main`.

Matrix:
- Flutter `3.32.0` (minimum supported)
- Flutter `3.41.0` (active baseline)

Quality gates:
- `flutter pub get`
- `dart run build_runner build --delete-conflicting-outputs`
- `git diff --exit-code` (generated files committed)
- `dart format --set-exit-if-changed .`
- `flutter analyze`
- `dart run custom_lint`
- `flutter test --coverage`

Coverage artifact:
- `coverage/lcov.info` uploaded per matrix job

## Release (`release.yml`)

Triggered on tags `v*`.

Steps:
- install dependencies
- generate code + verify committed
- run quality gates (including coverage)
- build Android release APK
- upload APK artifact (`app-release.apk`)
- create/update Forgejo release for the pushed tag via API
- classify prerelease tags (`-alpha.N`, `-beta.N`, `-rc.N`) as prerelease
- attach `app-release.apk` to the Forgejo release

Required repository secret/variable:
- `FORGEJO_TOKEN` (secret): token with release write access
- `FORGEJO_SERVER_URL` (variable, optional): defaults to `${GITHUB_SERVER_URL}`

## Maintenance (`maintenance.yml`)

Scheduled weekly and manually runnable.

Runs:
- `flutter pub outdated`
- `dart pub outdated`

This surfaces dependency drift for manual upgrade planning.
