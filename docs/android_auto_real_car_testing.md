# Android Auto Real-Car Testing

This runbook validates Navis on a physical Android Auto head unit using default
phone settings. It is intentionally separate from DHU testing: DHU is a local
projection smoke test, while a real car also enforces trusted install-source
policy.

Android Auto real-vehicle testing expects apps to be installed from a trusted
store such as Google Play or ONE store. Sideloaded APKs can be useful for DHU
and local development, but they are not a supported default-user path for
real-car visibility.

Official references:

- Android for Cars testing: https://developer.android.com/training/cars/testing
- Android Auto platform distribution: https://developer.android.com/training/cars/platforms/android-auto
- Media app manifest requirements: https://developer.android.com/training/cars/media/configure-manifest

## Package IDs

Register and test both Android package IDs in Play Console:

- Stable: `com.navis.app.navis`
- Dev sidecar: `com.navis.app.navis.dev`

Use the same release signing lineage that future updates will use. If Play App
Signing is enabled, keep upload keys and app-signing lineage consistent per Play
Console guidance.

## 1. Build Release Artifacts

Stable package:

```bash
flutter build appbundle --release
```

Dev sidecar package:

```bash
NAVIS_APP_ID_SUFFIX=.dev NAVIS_APP_NAME="Navis Dev" \
  flutter build appbundle --release
```

For Internal App Sharing, APKs are also acceptable:

```bash
flutter build apk --release
NAVIS_APP_ID_SUFFIX=.dev NAVIS_APP_NAME="Navis Dev" ./tool/dev_app.sh apk
```

## 2. Upload Through Play

For each package ID, upload the release artifact through one of these paths:

- Play Internal App Sharing for quick ad hoc validation.
- Play Internal Testing for a repeatable tester group.

Install the generated Play link on the phone. Do not install the APK through
`adb`, a browser download, a file manager, or another sideload path for this
test.

## 3. Keep Android Auto Defaults

Leave Android Auto developer mode and Unknown sources off for the real-car test.
This verifies the path a normal user will have. Unknown sources is only useful
for local sideload/DHU development and should not be required for release
validation.

## 4. Verify Phone State Before Connecting

Connect the phone with `adb` and run:

```bash
./tool/verify_android_auto_manifest.sh
./tool/diagnose_android_auto.sh com.navis.app.navis
./tool/diagnose_android_auto.sh com.navis.app.navis.dev
```

For a specific device:

```bash
./tool/diagnose_android_auto.sh com.navis.app.navis R5GL16JTNNN
```

The diagnostic script prints:

- package ID, version, install time, and update time
- installer source
- signing certificate digest when `apksigner` or `keytool` is available
- Android Auto package version
- `MediaBrowserService` resolver visibility
- canonical `com.ryanheise.audioservice.AudioService` manifest registration
- media session state for Navis
- filtered Android Auto, AudioService, Flutter, and crash logs

The script exits non-zero when the installer is not trusted for default
real-car Android Auto visibility. A Play-installed build should report
`com.android.vending` as the installer. If a regional trusted store uses another
installer package, pass it explicitly:

```bash
NAVIS_ANDROID_AUTO_TRUSTED_INSTALLERS="com.android.vending your.store.package" \
  ./tool/diagnose_android_auto.sh com.navis.app.navis
```

## 5. Clear Stale Android Auto State

If the diagnostic passes but Navis is still missing from the car launcher or
Customize launcher list:

```bash
adb shell am force-stop com.google.android.projection.gearhead
adb shell am force-stop com.google.android.gms
```

Then reconnect the phone to the vehicle. If the launcher cache still appears
stale, clear Android Auto storage from Android Settings and repeat the install
and diagnostic steps.

## 6. Real-Car Checklist

With the Play-installed build and Unknown sources off:

- Navis appears in Android Auto launcher or Customize launcher.
- Tapping Navis opens the browse tree.
- Liked, Recent, Playlists, and Library load as the four root destinations.
- Liked exposes Instant Mix, Instant Radio, Songs, and Albums, plus Shuffle
  Liked when liked songs exist.
- Recent conditionally exposes Resume Queue before recent songs.
- Library exposes Downloads when present, followed by Albums, Artists, and
  Genres.
- Tapping a playable item starts playback.
- Selecting a playlist song preserves playlist order from the selected song.
- Play, pause, next, previous, and seek work from the head unit.
- Now-playing metadata and artwork update.
- Disconnecting and reconnecting the phone preserves playback state.

Repeat the same checklist for `com.navis.app.navis` and
`com.navis.app.navis.dev`.

## Negative Control

To prove the trust gate is the difference:

1. Sideload the APK with `adb install`.
2. Keep Android Auto Unknown sources off.
3. Run `./tool/diagnose_android_auto.sh <package>`.
4. Confirm the script warns that default real-car visibility is not expected.

The sideload can still be valid for DHU/local development. It should not be used
as evidence that a default real-car install is release-ready.
