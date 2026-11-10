# iOS Testing Playbook

This guide defines how to validate Navis on iOS. Testing is simulator-first; a physical iPhone is used only for what the simulator cannot answer (section 3), and the owner is told beforehand because the phone is borrowed. Scope and item state live in the [iOS parity plan](../plans/iOS_Parity_Plan.md).

## 1) Host setup

```bash
./tool/multi_os_host_preflight.sh --auto-fix --doctor
```

Install an iOS Simulator runtime in Xcode > Settings > Platforms and boot an iPhone 17 simulator. Use one heavy job at a time; Flutter and Xcode builds together can exhaust an 8 GB Mac.

## 2) Simulator workflow

Compile check (the same command CI runs, see [ci-cd.md](../development/ci-cd.md)):

```bash
flutter build ios --simulator --debug
```

Runtime loop: iOS debug builds on the simulator expose the authenticated diagnostics API, so behaviour is checked through the app API, logs and inspected screenshots rather than by eye. The setup, the `NAVIS_DIAGNOSTICS_DEVICE=ios` launchers, handshake and build-time caveats are described once in the iOS simulator loop of [development-workflow.md](../development/development-workflow.md#desktop-app-api); the launcher helpers are in `tool/lib/diagnostics.sh`. Sign in with a disposable account on a test server, never a personal one. Keep evidence (logs, screenshots) under `build/ios-diagnostics/<item>-run/` in the main checkout; it is local and not committed, and a removed worktree takes its own `build/` with it.

Valid on the simulator: playback logic (stream through the loopback proxy, permanent download, rolling cache, seek, queue, gapless, crossfade, ReplayGain, speed, independent pitch through the tap's measured frequency ratio in `/v1/equalizer` (`pitchInputHz`, `pitchOutputHz`, `pitchResetCount`)), the equalizer via `/v1/equalizer`, LAN-IP http and https servers, sign-in and relaunch, the downloads folder and backup exclusion, layout at large text sizes and with Reduce Motion. Simulator timing and performance numbers are not valid.

Position clock (I45, #526): native just_audio stamps the position when `timeControlStatus` turns Playing, but the item clock can start later. The 200 ms observer (`checkForDiscontinuity`) now re-stamps the stamp silently when it drifts more than 50 ms, on every OS version; it never enters buffering on iOS 10+. After a change to it, rerun the `run_i526_ios.sh` probe (`PHASES="N E R"`) and the #539 radio pass. Pass: first-item over-run <= 80 ms in phase N, gapless <= 80 ms, R `r1` < 60 ms, E `e1` and `e2` < 60 ms, no stall flip to buffering and no event spam in steady playback (native events per minute not above the pre-fix count).

## 3) What the simulator cannot test

- Lock screen and Control Center Now Playing: artwork, scrubbing, remote commands.
- AirPods and headphone buttons; AirPlay and other routes.
- Interruptions (calls, Siri, alarms) and background survival under memory pressure.
- The local network permission prompt (the simulator does not enforce it).
- The keychain on hardware: `first_unlock_this_device` access while locked, and a second sign-in over an existing item.
- VoiceOver wording and focus order (the simulator's Accessibility Inspector is not a substitute).
- Audible equalizer A/B, CPU on high-resolution files, thermal behaviour.
- Profile and release builds (the simulator runs debug builds only).

## 4) Device-pass checklist

Run once on a physical iPhone, signed in to a real server, in a TestFlight build (the owner has the paid Apple Developer Program since 2026-11-07; see I7). Note pass or fail and the commit hash for each line.

- Lock screen and Control Center show title, artist, album, artwork and a moving position; scrubbing there seeks; play, pause, next and previous work.
- Background playback survives locking the phone and switching apps; playback continues to the next track while locked (keychain readable while locked).
- AirPods and wired headphone buttons: play/pause, double-press next, triple-press previous.
- Interruptions: a phone call or alarm pauses playback and it resumes afterwards when appropriate.
- Local network: the prompt appears when connecting to a LAN server, and streaming works after Allow.
- Keychain: sign in, force-quit and relaunch (still signed in); sign in a second time over the existing item.
- Equalizer: the audible A/B, AirPlay output, and CPU on a high-resolution file are acceptable.
- Pitch (I21): the audible quality at +-12 semitones and at the 0 to non-0 switch (a 20 ms splice that repeats one AU latency, about 90 ms), the song tail at the end of the queue (does AVPlayer render its post-end blocks so the AU's last 90 ms is heard), CPU on a 96 kHz file with pitch on, the lock screen with pitch on, an interruption and backgrounding with pitch on, and AirPlay.
- Files app: downloads appear under Navis > Downloads; a file deleted there is dropped from Navis downloads at the next launch.
- VoiceOver: buttons are labelled and focus order is sensible on Now Playing, the mini player and settings; check at an accessibility text size.

## 5) Log capture for defects

Attach the exact commit hash, iOS version and device model (or simulator runtime), reproduction steps, expected versus actual behaviour, and the app log (`flutter run -d <device> -v`, or the diagnostics API logs on the simulator).
