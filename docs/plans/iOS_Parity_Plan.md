# iOS parity plan

Goal (owner, 2026-11-07): ship iOS alongside macOS in 1.5.2 if feasible. iOS is
a complete Navis mobile client with Android as the reference: all audio
playback works, caching keeps the permanent download → rolling cache → stream
order, and the system integration matches popular iPhone players (lock screen
and Control Center with artwork and scrubbing, AirPods and headphone
controls, interruptions, background playback).

iOS work must not change Android, Linux, Windows or macOS behaviour: gate
changes on `Platform.isIOS` (or `isMacOS || isIOS` for shared Darwin code). A
change to a shared path is called out in its PR as cross-platform, carries
evidence for the other platforms, and gets a risky-change review.

This file is the durable ledger. Each item gets its own branch and pull
request against `dev`; update the item's row when its state changes. The
macOS counterpart is [macOS_Parity_Plan.md](macOS_Parity_Plan.md).

## Inventory (dev at `46883b4d`, 2026-11-07)

Sources: every `Platform.is*` branch in `lib/`, `ios/`, `third_party/`,
`pubspec.yaml`, CI and `tool/`, plus `flutter build ios --release
--no-codesign` on one Apple silicon Mac (Xcode iOS 27.2 SDK), which succeeded
(36.6 MB `Runner.app`, no tracked files modified). Nothing has run on a
simulator or device yet; every runtime claim is *unverified*.

| Feature | Android (reference) | iOS today | Evidence |
|---|---|---|---|
| Audio backend | just_audio + Media3 | just_audio on AVFoundation (vendored `third_party/just_audio` Darwin source) in debug and release; media_kit is desktop-only | `lib/main.dart:277-311`, `pubspec.yaml`, `third_party/just_audio/pubspec.yaml` |
| Equalizer | Media3 PCM EQ | off (capability false; Media3 on Android and libmpv on desktop implement it, AVFoundation does not) | `lib/src/features/equalizer/data/eq_platform_support.dart:12-46` |
| Fast seeking (transcode offset) | yes | off, setting hidden | `eq_platform_support.dart:35-46`, `playback_settings_screen.dart:264-270` |
| Speed / pitch | speed + independent pitch | speed yes, pitch off (UI hidden) | `playback_adjustments.dart:146-169`, `navis_audio_handler.dart:3081-3088` |
| Gapless, crossfade, ReplayGain | yes | no iOS gate; *unverified* on AVFoundation | `navis_audio_handler_crossfade.dart`, `navis_audio_handler.dart` |
| Stream proxy | loopback proxy for request headers; cleartext allowed only to `127.0.0.1` | same loopback proxy (`useProxyForRequestHeaders: !_isDesktopRuntime`); ATS `NSAllowsArbitraryLoads=false`, no exceptions (API calls use `dart:io`, which ATS does not govern; AVPlayer only reaches the loopback proxy). Verified 2026-11-07 (I2, simulator): a plain-http LAN-IP server and the https server both stream through the proxy (`kind=lockCachedStream`, rolling-cache files filled). http to a remote host is allowed with a login warning, as on Android | `navis_audio_handler.dart:913`, `ios/Runner/Info.plist`, `android/app/src/main/res/xml/network_security_config.xml` |
| Local network | no prompt | `NSLocalNetworkUsageDescription` set (I2, also on macOS); a LAN-IP server logs in and streams on the simulator, which does not enforce the prompt: the prompt itself is an I5 device check | `ios/Runner/Info.plist` |
| Background audio | foreground service + audio focus | `UIBackgroundModes: audio`, `AudioSessionConfiguration.music()`, interruptions handled manually | `Info.plist`, `navis_audio_handler_support.dart`, `navis_audio_handler.dart:905-928` |
| System media controls | audio_service notification + AVRCP | vendored audio_service Darwin plugin (M12 fixes shared with macOS); `projectTime` true (real-time projection kept, M13); never run on iOS | `navis_audio_handler_bootstrap.dart:164-211`, `real_time_projection_audio_handler.dart` |
| Car | Android Auto media tree | no CarPlay entitlement or scene | `ios/Runner/Info.plist`, `docs/project/progress.md` |
| Credentials | Keystore, durable write required | plugin default keychain, no `IOSOptions`; `requiresDurableCredentials` unset, so it falls back to `Platform.isAndroid` (false): a failed write degrades to a session-only login with only a log warning | `secure_credential_store.dart:202-234` |
| Downloads folder | app storage or SAF tree | **I4/I14 (in review):** `<Documents>/Downloads`, shown in Files; no custom folder (settings show a note); downloads and permanent artwork excluded from backup; the database moved to application support | `permanent_download_path_resolver.dart`, `downloads_screen.dart`, `download_storage_capacity.dart` |
| Self-update | APK | correctly off (repository returns null, update UI hidden) | `update_repository.dart:114`, `about_screen.dart:55-56` |
| Notifications, background sync | Android-only | none (early returns) | `library_sync_notifier.dart:30`, `notification_bootstrap.dart:21` |
| Shell / navigation | touch shell | touch shell, Cupertino back-swipe pages | `app_router.dart:62` |
| Diagnostics API (runtime loop) | profile builds | off: `_syncDiagnosticsRuntimeEnabled` excludes iOS, and the simulator cannot run profile builds | `lib/main.dart:541-549`, `tool/lib/diagnostics.sh` |
| Native project | – | bundle id `com.navis.app.navis`, iOS 16.0, iPhone + iPad, SwiftPM plugins only (I6 removed the CocoaPods integration: no `Podfile`, no Pods build phases or xcconfig includes), launch screen is the `LaunchBackground` colour (`#141313`, the dark Material surface of the default seed; dark-only because the app's default theme is dark whatever the system appearance) with the `LaunchLogo` mark recoloured from the app icon, no entitlements file, `ITSAppUsesNonExemptEncryption` false, `NSLocalNetworkUsageDescription` (I2), privacy manifest declares no tracking and no collected data plus disk space (E174.1) and file timestamps (C617.1, `sqlite3.framework`) | `ios/Runner.xcodeproj/project.pbxproj`, `ios/Runner/Base.lproj/LaunchScreen.storyboard`, `ios/Runner/PrivacyInfo.xcprivacy` |
| Release | Play / APK | I7: `tool/release.sh` builds an App Store IPA (`ios/ExportOptions.plist`, team `BFBNSCVKXH`) and, with `--ios-upload`, uploads it with `altool`; the IPA is no longer a release asset | `tool/release.sh`, `docs/release/release-ios.md` |
| Licences | – | nothing extra (no libmpv in the iOS bundle) | `lib/src/app_licenses.dart:39-49` |
| CI / docs | Android in CI | no iOS job; docs call iOS an unreleased scaffold; README lists no iOS | `.github/workflows/ci.yml`, `docs/development/technical-overview.md:10` |

## Items (triage approved by the owner, 2026-11-07)

| # | Item | Risk | State | PR |
|---|---|---|---|---|
| I0 | Runtime loop on the iOS simulator: enable the diagnostics API in iOS **debug** simulator builds (iOS uses AVFoundation in debug and release alike, so debug evidence holds for playback logic; profile needs a device), and teach `tool/lib/diagnostics.sh` an `ios` device. Follow-up for I1, done: the debug Riverpod assertion ("Tried to modify a provider while the widget tree was building") came from `ServerReachabilityController` and `LibrarySyncController` writing state in their `serverConfigStateProvider` listeners, which run inside `NavisApp.build` when the first read flushes the stale session config. Both now go through `runOutsideWidgetBuild` (with a per-listener gate that drops a deferred delivery superseded by a later one) (`lib/src/utils/run_outside_widget_build.dart`: defers one microtask in debug while a build is in progress, synchronous otherwise), and the debug-only router prewarm in `lib/main.dart` is removed | low (diagnostics only) | merged | #322, #339 |
| I1 | Runtime-verify playback on the simulator: stream through the loopback proxy, permanent download, rolling cache, seek, gapless, crossfade, ReplayGain, speed, queue, background and interruptions. Fix what fails | risky (playback) | runtime pass done 2026-11-07 (simulator, real server): stream, download, rolling cache, seek, queue/gapless, crossfade, ReplayGain, speed, background pass; interruptions untestable on the simulator (I5); fixes: crossfade-off not applied (#328), recorder replayNearEnd false positive (#327) | #328, #327 |
| I2 | Network: add `NSLocalNetworkUsageDescription`; prove a LAN-IP server and an https server stream; keep the Android-equivalent https-only policy unless I1 proves the loopback proxy needs an ATS exception | risky (network) | done 2026-11-07 (simulator, iPhone 17): `NSLocalNetworkUsageDescription` added to the iOS and macOS `Info.plist`; fixture server (`tool/auth_lifecycle_fixture_server.py --bind <LAN IP>`, new flag) on `<Mac LAN IP>`, plain http: login succeeds, the "HTTP does not encrypt traffic" note shows, a song streams (`Playback source resolved ... kind=lockCachedStream`, the loopback-proxy path, rolling-cache file filled); the https server with the disposable account streams too (FLAC cache files grew); no ATS exception needed. Evidence under `build/ios-diagnostics/i2-run/` (local, not committed) | #353 |
| I3 | Credentials: `IOSOptions` (accessibility `first_unlock_this_device` (owner 2026-11-07: matches Android's no-backup policy) so background playback can read the session while locked, Navis service name), durable write required on iOS as on Android | risky (auth) | merged | #325; simulator sign-in and relaunch verified; lock needs I5; this-device follow-up |
| I4 | Downloads folder: hide the custom-folder picker on iOS (the app container is the only durable place without bookmarks); mark permanent downloads and caches excluded from iCloud backup (`isExcludedFromBackup`; nothing sets it today, and App Review rejects backed-up re-downloadable media); optionally expose downloads in the Files app | low | merged 2026-11-07 (`ebdbe05f`): `<Documents>/Downloads` root on iOS, no custom folder (settings note, persisted choice ignored), `isExcludedFromBackup` on the downloads root and the permanent artwork root, database moved out of `Documents`, stored absolute paths rebased to the current container when iOS changes its UUID; evidence in the PR description and [progress.md](../project/progress.md) | #350 |
| I5 | Device pass: lock screen, Control Center, AirPods, artwork, scrubbing, background survival on the owner's iPhone (a TestFlight build once I7 lands; paid programme since 2026-11-07); the local network prompt appears for a LAN server and streaming works after Allow; a second sign-in over an existing keychain item (PR #347 Opus review: the plugin's `containsKey` synced-first query with this-device accessibility is unverified on hardware) | risky (system integration) | approved; device only when really needed, owner told beforehand (borrowed iPhone) | – |
| I6 | Native project: drop the leftover CocoaPods integration, real launch screen, `ITSAppUsesNonExemptEncryption`, privacy manifest entries for the APIs used | low | merged 2026-11-07 (`eee9daa2`): CocoaPods removed, dark-only launch screen, `ITSAppUsesNonExemptEncryption` false, privacy manifest (no tracking/collected data, E174.1, C617.1); Flash review nothing blocking; launch screen look pending the next simulator runtime pass | #348 |
| I7 | Release path: TestFlight/App Store upload in `tool/release.sh` (App Store Connect API key, export options), App Store privacy answers | risky (release) | approved (owner: TestFlight/App Store); the owner now has the paid Apple Developer Program (2026-11-07), so this is unblocked | merged 2026-11-07 (`a3404a77`): App Store IPA via `ios/ExportOptions.plist`, `--ios-upload` (altool, ASC key preflight), increasing build numbers from `tool/dev_build_number.py`, [release-ios.md](../release/release-ios.md); Sonnet review, findings fixed. follow-up #370 (`e3a3fc73`: manual App Store profile signing, system rsync for export, photo-library purpose string); first TestFlight upload 2026-11-07, build 37332319 from `e3a3fc73`, processed ("Ready to Submit"). Owner to confirm the privacy-label answers before App Store submission; external testing needs a public demo server (owner, later) | #364 |
| I8 | Docs and CI: iOS status in README and `technical-overview.md`, an iOS testing playbook, an iOS build check (`flutter build ios --no-codesign`) on a macOS runner if CI minutes allow | low | merged 2026-11-07 (`5bec003d`, iOS CI job green): README iOS row and "iOS status" section, `technical-overview.md` row, [iOS testing playbook](../platforms/ios-testing-playbook.md) (simulator workflow, what the simulator cannot test, the I5 device checklist), and a CI `ios` job (`macos-latest`, `flutter build ios --simulator --debug`, 30-minute limit, required by the `ci` aggregate; the simulator build needs no signing and is the build the runtime loop uses; no CocoaPods step since I6). The README Platforms badge stays unchanged until iOS is released | #358 |
| I9 | Equalizer on iOS (owner 2026-11-07: iOS does not ship without EQ). AVFoundation exposes no PCM to just_audio; candidate: an `MTAudioProcessingTap` on each `AVPlayerItem` in the vendored `third_party/just_audio` Darwin code running Navis's EQ bands as biquads (one tap per player, so crossfade keeps working), fed by the existing EQ settings; the alternative, an `AVAudioEngine` player with `AVAudioUnitEQ`, is a far larger rewrite. Opus feasibility done 2026-11-07: tap approach chosen (AVAudioEngine would replace the whole Darwin player and risk the download → cache → stream order); build plan in [macOS_iOS_Handoff_2026-11-07b.md](macOS_iOS_Handoff_2026-11-07b.md) | risky (playback, native, realtime) | merged 2026-11-07 (`413dabc7`) after three Sonnet/Opus review rounds; simulator proof via `/v1/equalizer` (levelDeltaDb −12.000 at flat −12 dB, 0 off; local, proxied, download, gapless, crossfade, 1.5×; resetCount flat in steady play at 44.1/48/96 kHz, +1 per seek/resume). Device checks (audible A/B, AirPlay, lock screen, CPU on hi-res, interruptions) go to I5. Deviation from the plan: taps attach to the current and next queue item, not at every item insertion, to avoid loading the tracks of a whole queue over the network | #335 |
| I10 | Independent pitch on iOS (owner 2026-11-08: 1.5.2). Opus feasibility 2026-11-08: `AUNewTimePitch` at rate 1 inside the I9 `MTAudioProcessingTap` (offline check: exact frame counts, correct pitch, ~0.8% CPU); open risk is the AU latency (4096 frames at 44.1/48 kHz) at item and seek boundaries (gapless, position). Next: simulator probe of prime/drain, then Opus plan, Sonnet build | risky (playback, native, realtime) | approved; probing | – |
| I11 | Sideload IPA on GitHub releases (owner 2026-11-08): an unsigned IPA for AltStore/SideStore attached to releases, built with a sideload-only define; that build shows a "new version available" notice linking to the release page (iOS cannot self-install). App Store/TestFlight builds keep no updater | moderate (release, update flow) | approved 2026-11-08; in review | PR pending |
| I10 | iOS layout polish (owner: one shared design plus iOS conventions, no Cupertino overhaul). Known: the Material `NavigationBar` is 80 pt plus the 34 pt home-indicator inset on iPhone (native tab bar 49 + 34), so shorten it on iOS; the transport row's left slot is an invisible EQ placeholder on iOS (fills once I9 lands). More from I11 | low (UI) | nav bar (64 pt on iOS) merged; transport slot verified 2026-11-07 on the simulator: the left slot shows the EQ button and opens the EQ sheet (screenshots taken during the PR #350 runtime pass) | #330 |
| I11 | Research: must-have features of popular iPhone music players, cross-referenced with Navis (DeepSeek Flash survey 2026-11-07; web fetch was unavailable, so claims rest on Apple's documented APIs and the code; gaps spot-checked by the coordinator). Result: items I12–I20 and the pending owner questions below | – | done; questions pending | – |
| I12 | AirPlay route picker: `AVRoutePickerView` in a `UiKitView`, iOS only; placement is an owner question (now-playing action row, or the transport row's left slot until I9 fills it). Verify playback survives route changes | low | **1.6**, as a cross-platform "Output device" button (iOS AirPlay picker, Android system output switcher, desktop audio-device list) | – |
| I13 | Sleep timer (none exists in `lib/`): timer in the handler with an optional "end of track", in the now-playing settings sheet, cleared on manual stop; shared code, so every platform gets it | low | **1.6** (all platforms) | – |
| I14 | Downloads in the Files app: `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`, permanent downloads exposed read-only, caches stay private; interacts with I4 (backup exclusion) | low | **1.5.2**, built together with I4 (downloads root in the Files-visible container from the start, so no later path migration); merged with I4 in #350 / `ebdbe05f` (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`; the folder is read-write in Files, not read-only; a file deleted in Files is dropped at the next launch, not re-downloaded, so downloads are best removed inside Navis; the per-track open-folder action is hidden on iOS; earlier test-build downloads under `Application Support/audio/permanent` are left as is) | #350 |
| I15 | Share sheet and `navis://` links: `UIActivityViewController` for song/album/playlist; `CFBundleURLTypes` is empty today; route through the existing router | low–medium | **1.6** (all platforms; the deferred Phase 28 share system) | – |
| I16 | Siri / Shortcuts via App Intents: play, pause, skip, like, "play <query>" into the existing handler | medium | **1.6** (iOS catching up with Android's voice search) | – |
| I17 | Live Activity / Dynamic Island and widgets (WidgetKit extension, app group) | medium | **1.6**, together with the Android home-screen widget (Phase 27) | – |
| I18 | Accessibility pass on iOS: Dynamic Type at accessibility sizes on now playing, transport and settings; VoiceOver labels; Reduce Motion | low | **1.5.2** (shared widgets, so Android benefits too); merged 2026-11-07 in #355 (`a7740d09`; review fixes: the 1.6x title cap is phone-strip only, 1.5x on the 90 dp compact-wide strip, desktop/tablet uncapped; Now Playing switchers and art-swipe snap-back honour Reduce Motion; five Linux goldens regenerated for the 44 pt transport row): Now Playing transport and Instant Mix buttons 44 pt on rows 340 dp and wider, mini player strip buttons 44 pt, mini title capped at 1.6x text, settings dropdowns `isExpanded` and the playback autosave line wraps, Reduce Motion stops the Appearance blinking icon and jumps Settings scroll-to-top and the mini player seek-preview fade; tests `now_playing_accessibility_test.dart`, `settings_accessibility_test.dart`, mini player case in `app_shell_navigation_test.dart`; simulator evidence in `build/ios-diagnostics/i18-run/`. **Deferred:** 44 pt transport buttons below 340 dp row width (phones under about 388 dp keep 40 pt), the album link under the title (37 pt tall at 2x), Android's 48 dp target in the transport row and mini strip, a few unlocalised strings in Playback settings, VoiceOver device pass | – |
| I19 | Background library sync and notifications on iOS (`BGTaskScheduler`, `UNUserNotificationCenter`) behind the existing Android-only seams | medium–high | **1.6** (iOS catching up with Android) | – |
| I20 | CarPlay (the CarPlay note below); needs the paid programme and Apple's entitlement | high | **1.6** (parity with Android Auto); request the entitlement as soon as the paid programme exists (approval takes weeks) | – |

### Scope decision from I11 (owner, 2026-11-07)

The owner asked for a split that avoids features on one platform but not the
others. Rule: **1.5.2 brings iOS up to what Android already has; new
features land in 1.6 on every platform at once.**

- **1.5.2 (iOS):** I9 (merged), I18, I4 with I14, plus the release items I2,
  I5, I6, I7, I8.
- **1.6, all platforms:** I13 sleep timer; I12 as an "Output device" button
  (AirPlay on iOS, the system output switcher on Android, the audio-device
  list on desktop); I15 share sheet and `navis://` links; I17 widgets on
  Android and iOS together, with Live Activity.
- **1.6, iOS catching up with Android:** I20 CarPlay (Android Auto), I16 Siri
  / App Intents (voice search), I19 background sync.
- Keychain (I3 follow-up): `first_unlock_this_device`, matching Android's
  `allowBackup="false"` with backup and device transfer excluded (owner
  delegated the choice; best practice).

Owner decisions (2026-11-07): distribution is TestFlight and the App Store.
Testing is simulator-first; the iPhone is borrowed, so a device pass is
requested only when the simulator cannot answer, with notice. CarPlay scope
is open (the owner asked what it takes; see the CarPlay note below).

Owner decisions (2026-11-07, I14 and I18 follow-ups):

- A download deleted in the Files app is dropped from downloads at the next
  launch, not re-downloaded (keep the current behaviour; the README says to
  remove downloads inside Navis).
- iPhone SE/mini (Now Playing transport rows under 340 dp) keep 40 pt
  transport buttons for 1.5.2.

Out of scope for 1.5.2 unless the owner decides otherwise: CarPlay (needs an
Apple-granted entitlement), fast seeking (independent pitch moved in scope as I10, owner 2026-11-08; the equalizer as I9, owner 2026-11-07), notifications and background library sync.

Order: I0 → I1 with I2 and I3 alongside, I4 and I6 as small parallel PRs, I5
when a build is ready for the owner's device, I7 once the paid programme
exists, I8 last.

## Owner actions

- Apple Developer Program (paid; owner has it since 2026-11-07) for TestFlight
  and App Store, and for a notarized macOS release; before that iOS installed
  only on the owner's own device with the free Personal Team (re-sign every
  7 days).
- An iPhone for the I5 device pass (borrowed: give notice, keep passes rare).

## CarPlay note (open owner decision)

CarPlay apps need Apple's CarPlay audio entitlement
(`com.apple.developer.carplay-audio`). It is requested with Apple's CarPlay
entitlement form by a paid Developer Program member, reviewed by Apple
(typically days to weeks), then added to the App ID and provisioning profile.
Work: a UIScene-based CarPlay scene in Swift using CarPlay templates (a tab
bar of browse lists plus the system Now Playing template), fed from the
existing Android Auto browse tree in the handler over a method channel; Now
Playing reuses the MPNowPlayingInfoCenter integration. It can be built and
tested in the Xcode simulator's CarPlay display before approval (*unverified*
for the entitlement check on the simulator).

### Small findings from the 2026-11-07e hand-off (triaged 2026-11-07)

- Fixed in #359 (`5c2816b2`): `sync_diagnostics.sh` alias-table crash, diagnostics DB discovery on macOS (iOS simulator via `NAVIS_DIAGNOSTICS_PRIMARY_DB`), fixture handshake `host`.
- Fixed in #360 (`b12adafc`): a failed iOS container-path rebase no longer re-downloads finish-journaled downloads (interrupted transfers still requeue); rename-failed copies go through `.navis-part` and refuse an occupied part name. Sonnet and Opus reviews, Sonnet re-review.
- By design, no change: end-of-sync `partial` (verification still pending).
- Deferred (low value or pre-existing, not 1.5.2 blockers): two `ping.view` calls at startup (log noise); `_moveFile` deletes the destination before a fallback copy; `promoteToPermanent` vs startup orphan-sweep race; a queued item without a journal whose permanent row has a stale path re-downloads on a failed-rebase launch; a crash mid-copy in a custom folder leaves an unowned `.navis-part` that blocks that destination until removed by hand.
