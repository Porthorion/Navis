# Android Auto Testing Guide (DHU)

This guide covers Android Auto phone projection through Navis' media browser
service. Projection discovers the app installed on the phone; it does not
install Navis onto the car. Android Automotive OS (AAOS) installability is a
separate target and should not be validated from this DHU checklist.

## Prerequisites

1. **Android Studio** with SDK Manager
2. **Android Auto Desktop Head Unit (DHU)** installed via:
   - Android Studio → Settings → Languages & Frameworks → Android SDK → SDK Tools tab
   - Check "Android Auto Desktop Head Unit Emulator"
3. **Physical Android device** (emulators don't support Android Auto) connected via USB
4. **Android Auto app** installed on the device (from Play Store)

## Setup

### 1. Enable Developer Mode on Phone

1. Open the **Android Auto** app on your phone
2. Go to **Settings** (gear icon)
3. Scroll to **Version** at the bottom
4. Tap the version number **10 times** to unlock Developer Settings
5. Tap the three-dot menu (⋮) → **Developer settings**
6. Enable **Unknown sources** (allows connecting to DHU without Google's review)

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

- [ ] Navis appears in the DHU's media app list
- [ ] Navis icon displays correctly
- [ ] Tapping Navis opens the media browse interface

### Browse Tree — Root Level

- [ ] All 5 root items display: Albums, Recent, Artists, Playlists, More
- [ ] Root items respond to touch within 1 second
- [ ] Each root item has appropriate text

### Browse Tree — Artists

- [ ] Artist list loads with names
- [ ] Artists with cover art show thumbnails
- [ ] Tapping an artist shows their albums
- [ ] Tapping an album shows track list
- [ ] Tapping a song starts playback
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

- [ ] More → Liked → Songs lists all starred songs
- [ ] Shows appropriate empty state if no starred songs
- [ ] Tapping a liked song starts playback

### Browse Tree — Liked Albums

- [ ] More → Liked → Albums shows starred albums
- [ ] Drill into album shows its tracks

### Browse Tree — Recently Played

- [ ] Recent songs appear (up to 50)
- [ ] Most recent plays appear first
- [ ] Tapping a song starts playback

### Browse Tree — More Actions

- [ ] More shows Liked, Instant Mix, and Instant Radio
- [ ] Tapping "Instant Mix" starts a seed-based mix when a current/known song is available
- [ ] Tapping "Instant Radio" starts playback from liked songs, server random songs, or local fallback

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
- [ ] Text search returns grouped results: Artists, Albums, Playlists, Songs
- [ ] Tapping a search result starts playback
- [ ] Empty search / "play music" starts Instant Radio (no crash)
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
2. Check that the `automotive_app_desc.xml` resource is in the APK:
   ```bash
   aapt dump xmltree build/app/outputs/flutter-apk/app-debug.apk res/xml/automotive_app_desc.xml
   ```
3. Verify the AndroidManifest `com.google.android.gms.car.application` metadata is at the
   **`<application>` level** — NOT inside the `<service>` block. Android Auto reads it from
   the application element to populate the launcher list; placing it inside a service causes
   silent failure (app never appears in the media list).
4. Verify Android Auto projection metadata is present on the phone app:
   `com.google.android.gms.car.application`,
   `androidx.car.app.TintableAttributionIcon`, and
   `com.google.android.gms.car.application.theme`.
5. **Do NOT add `android:permission="android.permission.BIND_MEDIA_BROWSER_SERVICE"` to the
   AudioService** declaration.  That permission has `protectionLevel="signature|privileged"`.
   On devices where Android Auto is installed from the Play Store (not a privileged system
   app), it does not hold that permission and gets `Permission Denial` when binding — which
   prevents Auto from connecting at all.  Caller validation is handled by
   `MediaBrowserServiceCompat.onGetRoot()` returning `null` for unauthorised callers.
6. Try restarting the head unit server on the phone
7. Try `adb forward tcp:5277 tcp:5277` again and restart the DHU (Android Auto uses
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
