# Android Auto Testing Guide (DHU)

This guide covers Android Auto phone projection through Navis' media browser
service. Projection discovers the app installed on the phone; it does not
install Navis onto the car. Android Automotive OS (AAOS) installability is a
separate target and should not be validated from this DHU checklist.

For default real-car validation, use the Play-installed trusted-source runbook:
[Android Auto Real-Car Testing](android_auto_real_car_testing.md).

## Prerequisites

1. **Android Studio** with SDK Manager
2. **Android Auto Desktop Head Unit (DHU)** installed via:
   - Android Studio → Settings → Languages & Frameworks → Android SDK → SDK Tools tab
   - Check "Android Auto Desktop Head Unit Emulator"
3. **Physical Android device** (emulators don't support Android Auto) connected via USB
4. **Android Auto app** installed on the device (from Play Store)

## Automated Cold-Start Regression Gate

Run this before the physical-phone DHU checklist whenever Android Auto startup,
audio bootstrap, notifications, or media browsing changes:

```bash
./tool/android_auto_cold_start_diagnostics.sh
```

It requires one running standard Android **phone emulator**. The command builds
and installs only `Navis Dev`, force-stops it, then runs a separate test-client
APK that binds the canonical `AudioService` as a head unit would. It never
launches `MainActivity`, and asserts the service initializes in 10 seconds and
returns the four root tabs: Liked, Recent, Playlists, and Library.

This is the repeatable automated regression test for the service-first path.
It does not replace the physical phone required for DHU phone projection.

## Setup

### 1. Enable Developer Mode on Phone

1. Open the **Android Auto** app on your phone
2. Go to **Settings** (gear icon)
3. Scroll to **Version** at the bottom
4. Tap the version number **10 times** to unlock Developer Settings
5. Tap the three-dot menu (⋮) → **Developer settings**
6. Enable **Unknown sources**. This is required for sideloaded APKs to appear
   in Android Auto's media app list. A real vehicle or DHU session can still
   hide a sideloaded app when this setting is off, even if the manifest is
   correct.

> For release validation, Google Play internal testing avoids the sideload
> visibility gate because Android Auto treats the install as trusted.

### 2. Start the Head Unit Server

On the phone:
- Android Auto → Developer settings → **Start head unit server**

### 3. Forward Port and Launch DHU

```bash
# Forward the Android Auto port
adb forward tcp:5277 tcp:5277

# Launch the DHU (path varies by OS)
# macOS:
~/Library/Android/sdk/extras/google/auto/desktop-head-unit

# Linux (see note below about missing libc++):
~/Android/Sdk/extras/google/auto/desktop-head-unit

# Windows:
%LOCALAPPDATA%\Android\Sdk\extras\google\auto\desktop-head-unit.exe
```

> **Linux — `libc++.so.1` not found:** Modern Linux distros don't ship the libc++ version
> that the DHU binary was linked against.  Resolve it via the NDK libraries that ship with
> Android Studio:
>
> ```bash
> NDK_LIB="$HOME/Android/Sdk/ndk/$(ls $HOME/Android/Sdk/ndk | sort -V | tail -1)/toolchains/llvm/prebuilt/linux-x86_64/lib"
> LLDB_LIB="$HOME/android-studio/plugins/android-ndk/resources/lldb/lib64"
> EMULATOR_LIB="$HOME/Android/Sdk/emulator/lib64"
> LD_LIBRARY_PATH="$NDK_LIB:$LLDB_LIB:$EMULATOR_LIB" \
>   ~/Android/Sdk/extras/google/auto/desktop-head-unit
> ```
>
> This is handled automatically by `./tool/dev_app.sh dhu`.

### 4. Build & Install Navis

```bash
# Build and install the dev variant
./tool/dev_app.sh run -d <device-id>

# Or build APK directly
flutter build apk --debug
adb install build/app/outputs/flutter-apk/app-debug.apk

# Verify the Android Auto manifest and packaged automotive descriptor
./tool/verify_android_auto_manifest.sh
```

## DHU Commands

Once the DHU is running, use these commands in the DHU terminal:

| Command | Description |
|---------|-------------|
| `day` | Switch to day mode (light theme) |
| `night` | Switch to night mode (dark theme) |
| `dpad up/down/left/right` | Navigate using D-pad |
| `dpad click` | Select/click current item |
| `dpad back` | Press back button |
| `keycode home` | Go to home screen |
| `keycode media_play_pause` | Toggle play/pause |
| `keycode media_play` | Media play |
| `keycode media_pause` | Media pause |
| `keycode media_next` | Next track |
| `keycode media_previous` | Previous track |
| `keycode search` | Open search |
| `mic begin` | Simulate voice input start |
| `restrict none` | Remove driving restrictions (unlocks UI during testing) |
| `restrict all` | Enable driving restrictions |

## Manual Test Checklist

### Connection & Discovery

- [ ] Force-stop Navis without opening `MainActivity`, then connect DHU; Navis
  loads its browse root without a crash, hang, or reconnect workaround
- [ ] Navis appears in the DHU's media app list
- [ ] Navis icon displays correctly
- [ ] Tapping Navis opens the media browse interface

### Browse Tree — Root Level

- [ ] All 4 root items display: Liked, Recent, Playlists, Library
- [ ] Root items respond to touch within 1 second
- [ ] Each root item has appropriate text

### Browse Tree — Library

- [ ] Library shows Downloads first when permanent downloads exist
- [ ] Library → Albums opens the album grid
- [ ] Library → Artists opens the artist list
- [ ] Library → Genres opens the genre list
- [ ] Artist list loads with names
- [ ] Artists with cover art show thumbnails
- [ ] Tapping an artist shows their albums
- [ ] Tapping an album shows track list
- [ ] Tapping a song starts playback
- [ ] Selecting a playlist song keeps the playlist order and starts at that song
- [ ] Scrolling through large artist list is smooth (>50 artists)

### Browse Tree — Albums

- [ ] Album list loads with cover art and artist name
- [ ] Albums displayed in grid layout (content style hint)
- [ ] Tapping album shows track list with song numbers
- [ ] Tapping song starts playback of full album queue from that track

### Browse Tree — Playlists

- [ ] All user playlists appear
- [ ] Playlist songs load in correct playback order
- [ ] Tapping a song starts playback from that position

### Browse Tree — Liked Songs

- [ ] Liked shows Instant Mix and Instant Radio first
- [ ] Shuffle Liked appears first when liked songs exist
- [ ] Liked → Songs lists all starred songs
- [ ] Shows appropriate empty state if no starred songs
- [ ] Tapping a liked song keeps the liked-song collection order
- [ ] Shuffle Liked starts a randomized liked-song queue

### Browse Tree — Liked Albums

- [ ] Liked → Albums shows starred albums
- [ ] Drill into album shows its tracks

### Browse Tree — Recently Played

- [ ] Resume Queue appears first only when a persisted queue exists
- [ ] Resume Queue restores the saved item and position
- [ ] Recent songs appear (up to 50)
- [ ] Most recent plays appear first
- [ ] Tapping a song keeps the recent collection order

### Browse Tree — Downloads and Genres

- [ ] Downloaded songs are available without a network connection
- [ ] Tapping a download keeps the downloaded-song collection order
- [ ] Genre songs load in artist/album/track order
- [ ] Tapping a genre song keeps the genre collection order
- [ ] Tapping "Instant Mix" starts the saved Server mix or Last.fm Same Vibes choice from the current song, or a library seed on cold start
- [ ] Tapping "Instant Radio" starts the same balanced personal radio used by Home, including eligible local fallback
- [ ] Preparing Instant Radio queues playable tracks without starting playback; an empty eligible library reports failure

### Playback Controls

- [ ] Play/Pause button works from DHU
- [ ] Next track button works
- [ ] Previous track button works
- [ ] Seek bar displays and responds to drag
- [ ] Album art displays on now-playing screen
- [ ] Song title displays correctly
- [ ] Artist name displays correctly
- [ ] Album name displays correctly
- [ ] Duration/progress bar updates in real-time

### Queue & State

- [ ] Switching songs from browse tree updates now-playing
- [ ] Queue persists when switching between phone and car
- [ ] Repeat mode toggle works
- [ ] Shuffle mode toggle works

### Search

- [ ] Search icon is available in the DHU toolbar
- [ ] Text search returns grouped results: Songs, Playlists, Albums, Artists
- [ ] Tapping a search result starts playback
- [ ] Empty search / "play music" starts Instant Radio (no crash)
- [ ] Playlist search works while the server is connected
- [ ] An unavailable server falls back to local search within 10 seconds
- [ ] Voice search via `mic` DHU command works for artist, album, playlist, genre, and title requests (requires Google Assistant)

### Day/Night Mode

- [ ] Run `day` command → UI adapts to light mode
- [ ] Run `night` command → UI adapts to dark mode
- [ ] Cover art thumbnails visible in both modes
- [ ] Text remains readable in both modes

### Error Handling

- [ ] Disconnect Wi-Fi → browse tree shows graceful error or cached data
- [ ] Reconnect Wi-Fi → browse tree recovers on next navigation
- [ ] Server unreachable → error message displayed (not a crash)
- [ ] Empty library (no synced data) → shows empty lists appropriately

### Edge Cases

- [ ] Very long song/album/artist names truncate properly (no overflow)
- [ ] Items with no cover art show without broken image
- [ ] Songs with missing metadata (no artist, no album) display gracefully
- [ ] Rapidly tapping browse items doesn't cause crashes or ANRs
- [ ] Phone app remains functional while connected to Auto
- [ ] Disconnect USB mid-playback → playback continues on phone speakers
- [ ] Reconnect to Auto → now-playing state syncs correctly

### Audio Focus

- [ ] Navigation voice prompt ducks Navis volume
- [ ] After navigation prompt → volume restores
- [ ] Incoming phone call pauses playback
- [ ] After call ends → playback resumes
- [ ] Opening another media app → Navis pauses

## Troubleshooting

### DHU doesn't show Navis

1. Verify the app is installed: `adb shell pm list packages | grep navis`
2. Confirm Android Auto Developer settings → **Unknown sources** is enabled
   for sideloaded APKs. Code cannot bypass this trusted-source gate.
3. Run the local manifest verifier:
   ```bash
   ./tool/verify_android_auto_manifest.sh
   ```
4. Check that the `automotive_app_desc.xml` resource is in the APK:
   ```bash
   aapt dump xmltree build/app/outputs/flutter-apk/app-debug.apk res/xml/automotive_app_desc.xml
   ```
5. Verify the AndroidManifest `com.google.android.gms.car.application` metadata is at the
   **`<application>` level** — NOT inside the `<service>` block. Android Auto reads it from
   the application element to populate the launcher list; placing it inside a service causes
   silent failure (app never appears in the media list).
6. Verify Android Auto projection metadata is present on the phone app:
   `com.google.android.gms.car.application`,
   `androidx.car.app.TintableAttributionIcon`, and
   `com.google.android.gms.car.application.theme`.
7. Confirm the service class is
   `com.ryanheise.audioservice.AudioService`. The plugin binds and starts this
   exact component during playback initialization; replacing it with an app
   subclass prevents the phone app from starting playback.
8. **Do NOT add `android:permission="android.permission.BIND_MEDIA_BROWSER_SERVICE"` to the
   AudioService** declaration.  That permission has `protectionLevel="signature|privileged"`.
   On devices where Android Auto is installed from the Play Store (not a privileged system
   app), it does not hold that permission and gets `Permission Denial` when binding — which
   prevents Auto from connecting at all.
9. Try restarting the head unit server on the phone
10. Try `adb forward tcp:5277 tcp:5277` again and restart the DHU (Android Auto uses
   exponential back-off after repeated connection failures; a fresh DHU session forces
   re-enumeration)

### Browse tree is empty

1. Check that the Navis library is synced (open the phone app, verify artists/albums appear)
2. Check logcat for errors: `adb logcat -s NavisAudioHandler,AudioService`
3. Verify `getChildren("root")` is being called by checking debug logs

### Cover art not showing

1. Cover art URLs require authentication — verify the server URL in the app settings
2. Check that the server is reachable from the phone's current network
3. Android Auto caches images; try clearing the Auto app cache

### Playback doesn't start

1. Check that `playFromMediaId` is being invoked (debug logs)
2. Verify the song exists in the local database
3. Check audio focus: another app might be holding audio focus

### DHU installation issues

If the DHU isn't in your SDK tools:
```bash
# Install via sdkmanager
sdkmanager "extras;google;auto"
```
