# MacBook Testing Playbook

This guide defines a repeatable process to validate Navis on a MacBook for development, regression testing, and release readiness.

## Scope

This playbook covers:
- macOS desktop runtime validation (`flutter run -d macos`)
- project quality checks on Mac host
- macOS release artifact build checks
- optional notarization readiness checks

It does not replace native Windows/Linux host validation for those platform artifacts.

## 1) One-time host setup

Run host preflight:

```bash
./tool/multi_os_host_preflight.sh --auto-fix --doctor
```

If needed, complete Apple setup:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

If iOS simulator testing is needed later, install Simulator runtimes via Xcode > Settings > Platforms.

## 2) Quick validation (10-20 min)

Use this before/after feature work:

```bash
./tool/multi_os_host_preflight.sh --doctor
./tool/release_gate_core.sh --quick
flutter build macos --debug --dart-define=NAVIS_UPDATE_CHANNEL=dev
flutter run -d macos --dart-define=NAVIS_UPDATE_CHANNEL=dev
```

Pass criteria:
- preflight returns no failures
- core release gate quick mode passes
- debug build succeeds
- app launches and audio playback works

## 3) Full regression validation (pre-merge / pre-release)

```bash
./tool/release_gate_core.sh
flutter build macos --release --dart-define=NAVIS_UPDATE_CHANNEL=stable
```

Expected artifact:
- `build/macos/Build/Products/Release/Navis.app`

Notes:
- warnings from third-party pods may appear; treat build failures as blockers.

## 4) Release packaging validation

Local release artifact build for macOS:

```bash
./tool/release.sh v0.x.y --targets=macos --skip-checks
```

For signed + notarized artifact flow:

```bash
export MACOS_SIGN_IDENTITY="Developer ID Application: <Team Name> (<TEAMID>)"
export MACOS_NOTARY_PROFILE="navis-notary-profile"

./tool/release.sh v0.x.y --targets=macos --macos-notarize --skip-checks
```

Store notary credentials once:

```bash
xcrun notarytool store-credentials navis-notary-profile \
  --apple-id "<apple-id>" \
  --team-id "<team-id>" \
  --password "<app-specific-password>"
```

## 5) Manual UI checklist on MacBook

- Launches to shell without crash.
- Can sign in and sync library.
- Now Playing/queue controls work (play/pause/seek/next/previous).
- Desktop window behavior works (open, resize, close, restore bounds).
- Audio continues across focus changes.
- Settings screens open and persist changed values.
- Update channel behavior is correct (`stable` vs `dev` build define).

## 6) Log capture for defects

Run with verbose logs:

```bash
flutter run -d macos -v --dart-define=NAVIS_UPDATE_CHANNEL=dev
```

Save logs with timestamps and attach:
- exact commit hash
- macOS version + chip architecture
- reproduction steps
- expected vs actual behavior

## 7) Recommended cadence

- During active feature work: section 2 per day or per major change.
- Before merge: section 3.
- Before release publish: section 4 + manual checklist in section 5.
