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
- After a launch with a restored queue, system Now Playing and the play key only include Navis once it has played audio in that launch (macOS policy, not a defect); after the first play they work, also while paused.
- Desktop window behavior works (open, resize, close, restore bounds).
- Audio continues across focus changes.
- Streaming against a TLS 1.3-only server fails on macOS while sign-in works (SecureTransport supports TLS up to 1.2, not a defect); test streams against a server that also allows TLS 1.2.
- Settings screens open and persist changed values.
- Update channel behavior is correct (`stable` vs `dev` build define).

## 6) Owner hands-on pass (macOS parity)

Run once on a Mac with a Developer ID build or a `--release` build (`flutter build macos --release`), signed in to a real server. Each line is one check with its expected result; note pass or fail and the commit hash. Items marked (release) need a release or profile build, because debug builds use AVFoundation.

Menus and window:
- Controls menu: with a song loaded, the menu bar has a "Controls" menu (before Window) with Play or Pause, Next and Previous and no shortcuts; the first item reads "Pause" while playing and "Play" while paused, flipping as you press it.
- Controls menu, nothing loaded: before anything is queued the items are disabled.
- Next with the window closed: close the window with the red button (music keeps playing), choose Controls > Next; the next song starts and the window stays hidden.
- Dock click: clicking the Dock icon reopens the hidden window.
- Dock menu: right-click the Dock icon; it shows "Title - Artist" plus Play or Pause, Next and Previous, and they work.
- Cmd+Q quits the app and stops the music (closing the window does not).
- Edit menu: click in the search field and paste with Cmd+V; the text pastes (the stock Edit menu is still in the menu bar).

System media:
- Hardware media keys (play/pause, next, previous) control Navis after the first play in the launch; with a restored paused queue and no play yet, macOS does not list Navis (expected, see section 5).
- Control Center and the menu-bar Now Playing show title, artist, album, artwork and a moving position; scrubbing there seeks.
- AirPods: press play/pause, double-press for next and triple-press for previous; Navis responds.

Update and release:
- Real self-update end to end: install an older notarized build in `/Applications`, publish a newer one to the dev channel, accept the update; the app quits, the new version opens, `~/Library/Logs/Navis/update.log` ends without errors, and no `Navis.app.backup` remains after the next launch.
- Forced rollback: publish an update whose app crashes at launch (or cannot start); the old version reopens within about 30 s and `update.log` says `restored previous app`.
- Translocation: run the update from the zip's Downloads copy; the dialog says to move Navis to the Applications folder.
- First `tool/macos_notarize.sh` run (`./tool/release.sh v0.x.y --targets=macos --macos-notarize`): signing, notarization and stapling finish, `spctl --assess --type execute --verbose=4 Navis.app` says accepted, and the zip opens with no Gatekeeper warning.

Streaming and hardware:
- Keychain-trusted private CA: a server whose certificate comes from a private CA you trusted in Keychain Access streams (and a server with a certificate nothing trusts does not).
- TLS 1.3-only server: sign-in works and streaming fails (expected on macOS; fine with TLS 1.2 also allowed).
- Intel hardware: the universal app launches, plays, and shows equalizer and Fast Seeking working (release) on an Intel Mac.
- Release-build playback (release): gapless playback, crossfade, speed and pitch, the equalizer (settings change the sound) and Fast Seeking (seek past the downloaded part of a lossless song and it resumes quickly) all work.
- Sign-in survives a restart: quit and relaunch; you stay signed in (a rebuilt ad-hoc dev binary may prompt for the keychain item).

Cover art (the cache store is shared with Android and iOS):
- Load: browse albums; covers appear.
- Restart: quit and relaunch; covers still appear (from the cache, also with the server off).
- Clear cache: Settings > Device Storage & Cache > Clear Cover Art Cache; the storage figure drops to zero and covers refetch as you browse.
- Change the limit: set Maximum Images, restart when asked; covers still load and the stored count stays near the limit.
- Sign-out: sign out and in again; covers load and nothing from the previous account shows.
- The same five cover-art checks on Android (a phone or emulator, release or profile build).

## 7) Log capture for defects

Run with verbose logs:

```bash
flutter run -d macos -v --dart-define=NAVIS_UPDATE_CHANNEL=dev
```

Save logs with timestamps and attach:
- exact commit hash
- macOS version + chip architecture
- reproduction steps
- expected vs actual behavior

## 8) Recommended cadence

- During active feature work: section 2 per day or per major change.
- Before merge: section 3.
- Before release publish: section 4 + the checklist in section 5 and the hands-on pass in section 6.
