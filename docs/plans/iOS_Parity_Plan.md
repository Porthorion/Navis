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
| Stream proxy | loopback proxy for request headers; cleartext allowed only to `127.0.0.1` | same loopback proxy (`useProxyForRequestHeaders: !_isDesktopRuntime`); ATS `NSAllowsArbitraryLoads=false`, no exceptions: matches Android's https-only policy; loopback and LAN behaviour *unverified* | `navis_audio_handler.dart:913`, `ios/Runner/Info.plist`, `android/app/src/main/res/xml/network_security_config.xml` |
| Local network | no prompt | no `NSLocalNetworkUsageDescription`; a LAN-IP server may fail without a prompt (*unverified*) | `ios/Runner/Info.plist` |
| Background audio | foreground service + audio focus | `UIBackgroundModes: audio`, `AudioSessionConfiguration.music()`, interruptions handled manually | `Info.plist`, `navis_audio_handler_support.dart`, `navis_audio_handler.dart:905-928` |
| System media controls | audio_service notification + AVRCP | vendored audio_service Darwin plugin (M12 fixes shared with macOS); `projectTime` true (real-time projection kept, M13); never run on iOS | `navis_audio_handler_bootstrap.dart:164-211`, `real_time_projection_audio_handler.dart` |
| Car | Android Auto media tree | no CarPlay entitlement or scene | `ios/Runner/Info.plist`, `docs/project/progress.md` |
| Credentials | Keystore, durable write required | plugin default keychain, no `IOSOptions`; `requiresDurableCredentials` unset, so it falls back to `Platform.isAndroid` (false): a failed write degrades to a session-only login with only a log warning | `secure_credential_store.dart:202-234` |
| Downloads folder | app storage or SAF tree | app-support default; the custom-folder picker is offered but has no security-scoped bookmark (*unverified*: likely lost after relaunch); downloads not visible in Files | `permanent_download_path_resolver.dart:47-56`, `downloads_screen.dart:1156-1161` |
| Self-update | APK | correctly off (repository returns null, update UI hidden) | `update_repository.dart:114`, `about_screen.dart:55-56` |
| Notifications, background sync | Android-only | none (early returns) | `library_sync_notifier.dart:30`, `notification_bootstrap.dart:21` |
| Shell / navigation | touch shell | touch shell, Cupertino back-swipe pages | `app_router.dart:62` |
| Diagnostics API (runtime loop) | profile builds | off: `_syncDiagnosticsRuntimeEnabled` excludes iOS, and the simulator cannot run profile builds | `lib/main.dart:541-549`, `tool/lib/diagnostics.sh` |
| Native project | – | bundle id `com.navis.app.navis`, iOS 16.0, iPhone + iPad, SwiftPM plugins but CocoaPods still integrated (build warning), blank launch image, no entitlements file, no `ITSAppUsesNonExemptEncryption`, privacy manifest declares disk space only | `ios/Runner.xcodeproj/project.pbxproj`, `ios/Podfile`, `ios/Runner/PrivacyInfo.xcprivacy` |
| Release | Play / APK | `tool/release.sh` makes an ad-hoc IPA only; no TestFlight or App Store path | `tool/release.sh:697-700` |
| Licences | – | nothing extra (no libmpv in the iOS bundle) | `lib/src/app_licenses.dart:39-49` |
| CI / docs | Android in CI | no iOS job; docs call iOS an unreleased scaffold; README lists no iOS | `.github/workflows/ci.yml`, `docs/development/technical-overview.md:10` |

## Items (triage approved by the owner, 2026-11-07)

| # | Item | Risk | State | PR |
|---|---|---|---|---|
| I0 | Runtime loop on the iOS simulator: enable the diagnostics API in iOS **debug** simulator builds (iOS uses AVFoundation in debug and release alike, so debug evidence holds for playback logic; profile needs a device), and teach `tool/lib/diagnostics.sh` an `ios` device. Follow-up for I1: a debug-only router prewarm in `lib/main.dart` (scoped to the simulator diagnostics run) works around a Riverpod assertion attributed to router listeners publishing state while mounting in `NavisApp.build`; the cause is unproven: reproduce it in a plain simulator debug run and fix it at the source, then drop the prewarm | low (diagnostics only) | merged | #322 |
| I1 | Runtime-verify playback on the simulator: stream through the loopback proxy, permanent download, rolling cache, seek, gapless, crossfade, ReplayGain, speed, queue, background and interruptions. Fix what fails | risky (playback) | approved | – |
| I2 | Network: add `NSLocalNetworkUsageDescription`; prove a LAN-IP server and an https server stream; keep the Android-equivalent https-only policy unless I1 proves the loopback proxy needs an ATS exception | risky (network) | approved | – |
| I3 | Credentials: `IOSOptions` (accessibility `first_unlock` so background playback can read the session while locked, Navis service name), durable write required on iOS as on Android | risky (auth) | in review (`feat/ios-i3-keychain`); runtime still to check: sign in on the simulator, relaunch keeps the session | – |
| I4 | Downloads folder: hide the custom-folder picker on iOS (the app container is the only durable place without bookmarks); mark permanent downloads and caches excluded from iCloud backup (`isExcludedFromBackup`; nothing sets it today, and App Review rejects backed-up re-downloadable media); optionally expose downloads in the Files app | low | approved | – |
| I5 | Device pass: lock screen, Control Center, AirPods, artwork, scrubbing, background survival on the owner's iPhone (free Personal Team signing, 7-day install) | risky (system integration) | approved; device only when really needed, owner told beforehand (borrowed iPhone) | – |
| I6 | Native project: drop the leftover CocoaPods integration, real launch screen, `ITSAppUsesNonExemptEncryption`, privacy manifest entries for the APIs used | low | approved | – |
| I7 | Release path: TestFlight/App Store upload in `tool/release.sh` (App Store Connect API key, export options), App Store privacy answers | risky (release) | approved (owner: TestFlight/App Store); needs the paid Apple Developer Program | – |
| I8 | Docs and CI: iOS status in README and `technical-overview.md`, an iOS testing playbook, an iOS build check (`flutter build ios --no-codesign`) on a macOS runner if CI minutes allow | low | approved | – |
| I9 | Equalizer on iOS (owner 2026-11-07: iOS does not ship without EQ). AVFoundation exposes no PCM to just_audio; candidate: an `MTAudioProcessingTap` on each `AVPlayerItem` in the vendored `third_party/just_audio` Darwin code running Navis's EQ bands as biquads (one tap per player, so crossfade keeps working), fed by the existing EQ settings; the alternative, an `AVAudioEngine` player with `AVAudioUnitEQ`, is a far larger rewrite. Opus feasibility plan first | risky (playback, native) | owner-required; planning | – |
| I10 | iOS layout polish (owner: one shared design plus iOS conventions, no Cupertino overhaul). Known: the Material `NavigationBar` is 80 pt plus the 34 pt home-indicator inset on iPhone (native tab bar 49 + 34), so shorten it on iOS; the transport row's left slot is an invisible EQ placeholder on iOS (fills once I9 lands). More from I11 | low (UI) | approved | – |
| I11 | Research: must-have features of popular iPhone music players (AirPlay route picker and others), cross-referenced with Navis; produces new items and owner questions, asked together once ready | – | owner-requested 2026-11-07 | – |

Owner decisions (2026-11-07): distribution is TestFlight and the App Store.
Testing is simulator-first; the iPhone is borrowed, so a device pass is
requested only when the simulator cannot answer, with notice. CarPlay scope
is open (the owner asked what it takes; see the CarPlay note below).

Out of scope for 1.5.2 unless the owner decides otherwise: CarPlay (needs an
Apple-granted entitlement), independent pitch on AVFoundation (new native
audio graph; the equalizer moved in scope as I9, owner 2026-11-07), fast seeking, notifications and background library sync.

Order: I0 → I1 with I2 and I3 alongside, I4 and I6 as small parallel PRs, I5
when a build is ready for the owner's device, I7 once the paid programme
exists, I8 last.

## Owner actions

- Apple Developer Program (paid) for TestFlight and App Store, and for a
  notarized macOS release; until then iOS installs only on the owner's own
  device with the free Personal Team (re-sign every 7 days).
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
