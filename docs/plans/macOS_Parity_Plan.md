# macOS parity plan

Goal (owner, 2026-11-04): macOS is a complete Navis desktop client. All audio
playback works, caching keeps the permanent download → rolling cache → stream
order, every Linux/Windows desktop feature works as well or better, and the
system integration matches popular Mac players (Now Playing in Control Center
and the menu bar with artwork, metadata and scrubbing; media keys; AirPods and
headphone controls; keyboard shortcuts; Dock menu). iOS is not a target yet,
but work that also serves iOS (AVFoundation/MediaPlayer, `audio_session`,
Darwin plugins) is preferred.

macOS work must not change Linux or Windows behaviour (owner): gate changes
on `Platform.isMacOS` (or `isMacOS || isIOS` for shared Darwin code). A change
to a shared path is called out in its PR as cross-platform, carries Linux and
Windows evidence, and gets a risky-change review.

This file is the durable ledger for the work. Each item gets its own branch
and pull request against `dev`; update the item's row when its state changes.

## Inventory (dev at `cd493f95`, 2026-11-04)

Sources: every `Platform.is*` / `defaultTargetPlatform` branch in `lib/`, the
`macos/`, `linux/` and `windows/` runners, `third_party/`, `pubspec.yaml`, and a
`flutter build macos --release` on one Apple silicon Mac, which succeeded (one
host; not yet repeated on CI or Intel). Rows marked *unverified* are
assumptions until an item proves them.

| Feature | Linux / Windows | macOS today | Evidence |
|---|---|---|---|
| Audio backend | media_kit + libmpv (Linux system bundle, Windows pinned full bundle `third_party/media_kit_libs_windows_audio`) | media_kit + `media_kit_libs_macos_audio` 1.1.4 (mpv 0.36, Mbed TLS, no libavfilter). Debug builds skip media_kit and use just_audio's AVFoundation player unless `NAVIS_ENABLE_MEDIA_KIT_DEBUG=true` | `lib/main.dart:265-297,538-539`, `pubspec.yaml:65,70` |
| Stream TLS verification | `tls-verify=yes`, system store | `tls-verify=yes` with `tls-ca-file=/etc/ssl/cert.pem` (Mbed TLS cannot use the system store); a private CA trusted only in the keychain is refused for streams. Branch `fix/macos-stream-tls-verify`, in review | `lib/src/bootstrap/bundled_libmpv.dart`, `docs/architecture.md` |
| Equalizer | libavfilter chain | **unavailable** (bundle lacks filters) | `lib/src/features/equalizer/data/eq_platform_support.dart:12-17` |
| Fast seeking (transcode offset) | yes | **off** (platform gate) | `lib/src/features/player/data/navis_audio_handler_recovery.dart:395-399`, `lib/src/features/settings/presentation/playback_settings_screen.dart:264-266` |
| Speed / pitch, gapless, crossfade, ReplayGain | yes | yes in release; speed/pitch absent in debug | `lib/src/features/player/presentation/playback_adjustment_controller.dart:17-21` |
| System media controls | Linux: app-owned MPRIS bridge. Windows: app-owned SMTC adapter | `audio_service` Darwin plugin (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`); **never runtime-verified** | `lib/src/features/player/data/navis_audio_handler_bootstrap.dart:164-211`, `docs/development/technical-overview.md:11,53` |
| System media artwork | local file from `_artCache` | `audio_service` fetches `artUri` through the guarded cache manager; unverified | `lib/src/features/player/data/navis_audio_handler.dart:155-161`, `navis_audio_handler_bootstrap.dart:193` |
| Audio session | not used | `AudioSessionConfiguration.music()` | `lib/src/features/player/data/navis_audio_handler_support.dart:12-13`, `navis_audio_handler.dart:916-919` |
| Window lifecycle | close persists state and quits | closing hides the window (full screen is left first); playback and the app keep running, Dock click reopens, Cmd+Q quits (M3a) | `lib/src/routing/desktop_window_controller.dart` (`onWindowClose`, `_persistThenHide`), `macos/Runner/AppDelegate.swift`, `macos/Runner/MainFlutterWindow.swift` |
| Dock menu / app menu playback commands | n/a | Dock menu: now playing, Play or Pause, Next, Previous (M3a); menu-bar Controls menu (Play or Pause, Next, Previous, no key equivalents; built in Swift, not `PlatformMenuBar`, so the stock Edit menu stays; M3c, built, in review) | `macos/Runner/AppDelegate.swift`, `lib/src/features/player/data/macos_dock_menu_bridge.dart` |
| Keyboard shortcuts | Ctrl bindings | Cmd bindings, Cmd+[ / Cmd+] (in-window only, same as other platforms) | `lib/src/routing/desktop_commands.dart:53-61,153-166` |
| Diagnostics API (runtime loop) | profile builds | **excluded** by the platform list; launch scripts hard-code `-d linux` | `lib/main.dart:526-531`, `tool/sync_diagnostics.sh:243` |
| Self-update | package / portable / installer modes | `macosBundle`: detached shell script replaces the `.app`. Unverified; `tool/macos_notarize.sh` re-signs with `--deep` and no `--entitlements`, so the shipped app is not sandboxed while `flutter build` output is | `lib/src/features/settings/data/update_install_mode.dart:46-58`, `update_service.dart`, `tool/macos_notarize.sh:87-93` |
| LGPL libmpv/FFmpeg notice | shown | **missing**, although the bundle ships libmpv | `lib/src/app_licenses.dart:39-41` |
| Cover-art cache store | flutter_cache_manager JSON store | sqflite store (shared with Android and iOS); *unverified*: in flutter_cache_manager 3.4.5 lookups hang after a failed open and `close()` before open completes crashes | flutter_cache_manager 3.4.5 `lib/src/config/_config_io.dart:38-42` (store selection) |
| Xcode project | n/a | `flutter build macos` rewrites `project.pbxproj` and the scheme for the Swift Package Manager plugin migration on every build | build of `cd493f95` |
| Equal everywhere (no gap) | tray icon, single instance, URL scheme, notifications, launch at login, output-device UI, Discord RPC: absent on all desktops | same | survey |

## Items

Risk follows `~/.claude/CLAUDE.md`: playback, file writes, auth, updaters and
native lifecycle are risky (Opus plan → Sonnet build → fresh Sonnet review,
plus Opus review for auth/file writes).

| # | Item | Risk | iOS carry-over | State | Branch / PR |
|---|---|---|---|---|---|
| M0 | Diagnostics API on macOS profile builds (`_syncDiagnosticsRuntimeEnabled`; launch sites hard-coding `-d linux`: `tool/lib/diagnostics.sh:202,247,296`, `tool/sync_diagnostics.sh:243`, `tool/presentation_diagnostics.sh:213`; the PulseAudio device that `tool/lib/diagnostics.sh:247-252` injects, which `lib/main.dart:284-290` would pass to libmpv, must not be used on macOS). Drops the App Sandbox from both entitlement files so the sandbox no longer blocks the clone root and handshake under `build/`, matching the notarized app, which `tool/macos_notarize.sh` re-signs without entitlements. Prerequisite for every runtime check below | risky (auth surface, profile only; entitlements) | no | merged (#240); owner approved dropping the sandbox 2026-11-04 | #240 |
| M1 | Runtime-verify Now Playing and remote commands through `audio_service`: metadata, artwork, position/duration/rate, scrubbing (`changePlaybackPosition`), play/pause/next/previous/seek from media keys, Control Center, AirPods. Fix what fails, then decide whether an app-owned Darwin bridge (like MPRIS/SMTC) is needed | risky (playback) | yes (same MediaPlayer APIs) | phase A done 2026-11-04 (see below); cold-start gap closed 2026-11-04 as macOS behaviour, no code change (see below); hardware keys and AirPods open | – |
| M2 | Replace the macOS libmpv bundle with a pinned full build (like Windows): system TLS verification, libavfilter equalizer, then lift the macOS gates for EQ and fast seeking. Interim if M2 is slow: `tls-verify=yes` with `tls-ca-file=/etc/ssl/cert.pem`, runtime-proven against a bad certificate | risky (playback, security) | no (iOS uses AVFoundation) | interim TLS merged (#244) (changelog line when released: "macOS: stream connections now verify server certificates."); bundle replacement triaged | – |
| M3 | Mac app lifecycle: keep running when the window closes, reopen on Dock click, Dock menu (play/pause, next, previous, now playing), Controls menu in the menu bar (native, from the Dock menu bridge) | risky (window/close lifecycle) | partly (commands) | M3a (close hides, Dock-click reopen, Dock menu) merged (#242); Controls menu (M3c) built, in review, branch `feat/macos-controls-menu`. It is native Swift on the Dock-menu bridge, not Flutter `PlatformMenuBar`, which would replace the whole menu bar and drop the stock Edit menu. Changelog lines for the next release (not yet in `changelog_data.dart`): "macOS: closing the window keeps music playing; click the Dock icon to reopen. The Dock menu shows the current track with Play/Pause, Next and Previous." and "macOS: a Controls menu in the menu bar plays, pauses and skips." | #242 |
| M4 | Self-update on macOS: prove download → replace → relaunch on a notarized build (unsandboxed after M0) and sign with explicit entitlements and hardened runtime rather than `--deep` re-signing | risky (file writes, updater) | no | triaged | – |
| M5 | Register the LGPL libmpv/FFmpeg notice on macOS. The bundled build (media-kit libmpv-darwin-build v0.6.0) is mpv 0.36.0 (LGPL-2.1+), FFmpeg 6.0 built `--enable-version3` (LGPL-3.0+) and Mbed TLS 3.4.1 (Apache-2.0), so the macOS entry carries the LGPL-2.1, LGPL-3.0 and Apache-2.0 texts. Hosting the corresponding source on downloads.porthorion.com (as for Windows/Linux) is an owner action; the notice points at the upstream release and build scripts meanwhile. Changelog line for the next release (not yet in `changelog_data.dart`): "macOS: the licences screen lists the bundled libmpv and FFmpeg libraries." | low | no | built, in review | `chore/macos-lgpl-notice` |
| M6 | Prove, then harden, the sqflite cover-art store against the reported 3.4.5 open/close bugs. Cross-platform: the store is shared with Android and iOS, so Android evidence is required | risky (cache, cross-platform) | yes | triaged | – |
| M7 | Commit the Swift Package Manager migration of the macOS Xcode project so builds stop dirtying the tree; the first build after a clean checkout can fail with "Unable to resolve module dependency" and pass on retry | low | yes (iOS project too) | built, in review: Flutter 3.47.5 has SwiftPM on by default and rewrites the project on the first build, so the migrated macOS and iOS projects are committed; the second build leaves the tree clean | `chore/macos-spm-migration` |
| M9 | Saved sign-in on macOS. The plugin's default data-protection keychain needs a `keychain-access-groups` entitlement no build has (`SecItemAdd` returned -34018, so the sign-in lasted one session). Fix: every `FlutterSecureStorage` uses the login keychain with a Navis-specific service name (`macOsLoginKeychain`) and on macOS the shortcut store shares the serialized native queue; ad-hoc dev rebuilds can prompt per item (see `docs/architecture.md`). Changelog line for the next release: "macOS: Navis keeps you signed in across restarts." | risky (auth) | yes (iOS keychain) | merged (#241, follow-up #243) (proven at runtime: `-34018` on the data-protection keychain; the login keychain persists across launches) | #241; follow-up #243 (a failed credential or ListenBrainz token delete is overwritten with an empty value or remembered as cleared so a stale account is never read back in the same session, and the service name is pinned by a test; covered by tests only, no runtime proof) |
| M8 | Docs: macOS status in `README.md`, `docs/architecture.md`, `docs/release/release-macos.md` (TLS gap, updater flow), macOS testing playbook. `docs/development/technical-overview.md` is corrected with this plan and again by M1 | low | – | after M1–M3 | – |
| M11 | macOS: a failed (404) stream reported `playing: true` with `processingState` idle (`stream_open_diagnostics` check `failedStreamNotPlaying`, intermittent: about 1 run in 4 on the first load after launch). Cause: libmpv opens a file after `open` returns, so the adapter reports the load ready, the handler issues Play, and the 404 lands 2 ms later. `_recoverCurrentSongFromRemotePlaybackFailure` skips a song while `_isLoading`, and a load that already returned never throws, so the failure was dropped and `playing` stayed true. Fix: `_completeQueueLoad` re-runs recovery for a failure that arrived after the source was applied; the diagnostics script reads the state again after its 3 s wait. Not macOS-specific, only exposed by its timing. Changelog line when released: "macOS: a song that fails to load no longer shows as playing." | risky (playback) | no | merged (#246) | #246 |

Order: M0 first (enables runtime evidence), then M1 and M2 (playback core),
M3, M4, with M5 and M7 as small parallel PRs and M8 last.

## M1 phase A results (2026-11-04)

Profile clone on macOS 27.2 against `tool/auth_lifecycle_fixture_server.py`,
system state read through MediaRemote from an Apple-signed host, commands sent
with `MRMediaRemoteSendCommand`.

- Works through `audio_service` 0.18.19 (`AudioServicePlugin.m`): title,
  artist, album and artwork in system Now Playing; duration, elapsed within
  about 0.5 s, rate 1 playing and 0 paused; play, pause, toggle, stop, next,
  previous; scrubbing (`changePlaybackPosition`) while playing and paused;
  Now Playing clears when the queue clears. No app-owned Darwin bridge is
  needed for these.
- Not set by the plugin: queue index and count (`AudioServicePlugin.m:317-320`),
  skip-interval, like and rating commands (`:131-135`).
- Cold start with a restored paused queue (cause proven 2026-11-04, branch
  `fix/macos-cold-start-now-playing`, no code change): the system shows no Now
  Playing entry and a system play command does nothing (earlier it opened
  Music.app) until Navis has played audio once. Navis does push a media item
  and a paused, ready playback state with play enabled for the restored queue,
  and the plugin sets Now Playing info with 8 keys (NSLog instrumentation).
  The plugin enables the command centre only on the first `playing` state
  (`AudioServicePlugin.m:179-184`), but a patched copy that enables it for a
  paused loaded item (command centre active, info set, paused playback state)
  changed nothing: MediaRemote still reported no client. After one real play
  the entry appears (title, artist, album, duration, rate 0) and stays after
  pause. So macOS only lists an app that has produced audio output in this
  launch; that is OS policy and cannot be fixed without playing audio (a silent
  or momentary play is a hack and was not added). Behaviour to expect: after
  launch, the play key and Now Playing work once the user has pressed play in
  Navis. Method: `build/m1c/run.py` (not tracked: fixture server, play, pause,
  quit, relaunch the same profile, read MediaRemote through a `swift` host,
  send `MRMediaRemoteSendCommand`).
- Not verified: hardware media keys and AirPods (scripted key events need
  Accessibility trust, not granted), Control Center and menu-bar visuals.
  Needs one manual pass on the Mac.

## Open questions

- M2 findings (2026-11-04): `media_kit_libs_macos_audio` 1.1.4 downloads
  `media-kit/libmpv-darwin-build` v0.6.0 `macos-universal-audio-default`
  (mpv 0.36.0, Mbed TLS). Its libavfilter has `equalizer` and `aresample` but
  no `volume` or `biquad` filters, which the Navis EQ chain needs
  (`third_party/just_audio_media_kit/lib/src/equalizer_chain.dart:42,58`).
  The mpv binary accepts `tls-verify` and `tls-ca-file`. The same project's
  v0.7.3 (2026-09-14) publishes `libmpv-xcframeworks_v0.7.3_macos-universal-audio-full`
  (and an iOS equivalent). Candidate: vendor the macOS libs package under
  `third_party/` pinned to v0.7.3 audio-full with a SHA-256, as Windows does,
  then set `tls-verify=yes` with `tls-ca-file=/etc/ssl/cert.pem` on macOS. Still
  to prove: filter list and licence flavour (full is LGPL; encodersgpl is not
  wanted). The interim (2026-11-04, v0.6.0 libs): `tls-verify=yes` alone refuses
  every HTTPS stream, even a valid public one; with `tls-ca-file` a public
  certificate plays and self-signed or wrong-host certificates are refused.
  For IP-literal hosts the host name is not matched; the chain is still
  verified.
- M3: owner preference on closing the window while playing. Default: keep
  playing (Apple Music, Spotify, Doppler behaviour); quit with Cmd+Q.
