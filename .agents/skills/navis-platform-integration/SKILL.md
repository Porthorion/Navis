---
name: navis-platform-integration
description: Navis native platform integration — plugin wiring on Android/iOS/macOS/Linux/Windows, background audio, Windows SMTC, Linux D-Bus MPRIS, Android Auto, window lifecycle, packaging, and per-target verification evidence. Use for any platform-specific bug, native bridge change, media-control integration, or packaging task.
metadata:
  author: ChatGPT
  version: '1.1'
  project: Navis
  origin: custom-not-official
  prepared: '2026-09-22'
  adapted: trimmed duplicated policy boilerplate, anchored to repo paths
---

# Navis Native Platform Integration

Task-scoped workflow for platform work. AGENTS.md and
`docs/development/agentic-engineering.md` are always loaded and govern scope and
validation; their Platform notes are the support matrix. Platform-neutral
behavior requires Linux runtime validation; platform-specific work needs
Linux startup smoke plus the affected platform's authoritative service/API
when available.

## Ground rules

Dependency presence does not establish completed implementation. Inspect the
platform directories, startup/backend registration, native plugin source,
manifests/entitlements, build files, CI, and packaging documentation for the
targets the task actually touches. Do not hand-edit generated plugin
registration, add duplicate integrations, or change the OS support matrix as
routine cleanup.

Known contracts (verify in source, do not restate from memory alone):

- **Android Auto** is MediaBrowserService projection, not a Flutter
  head-unit UI; keep the canonical
  `com.ryanheise.audioservice.AudioService` registration.
- **Linux** uses the app-owned D-Bus MPRIS bridge; dependency presence of
  `dbus` is not its implementation.
- **Windows** uses the tracked `third_party/navis_windows_smtc` Rust/WinRT
  adapter.
- **macOS** media controls remain incomplete; desktop media-kit skips debug
  macOS unless `NAVIS_ENABLE_MEDIA_KIT_DEBUG=true`.
- `third_party/just_audio_media_kit`'s progressive-stream seek
  customization is protected vendored behavior.

## Trace native event and ownership boundaries

For a system-control task, map: OS command → platform bridge → shared
playback command → backend event → metadata/state update. Check supported
units, capabilities, null/unknown values, and current-item identity in the
actual bridge. Prevent duplicate registrations, handlers, player instances,
and stale events after shutdown or track/account changes.

For Windows, inspect the local SMTC bridge's Dart/native ownership,
capability reporting, metadata/position updates, and teardown. For Linux,
inspect D-Bus service ownership and media-control mapping. For Apple and
Android, inspect the actual media-session, background, interruption,
entitlement/permission, and lifecycle paths. Verify platform APIs for the
resolved plugin and toolchain versions before editing native code.

Keep window close, minimize, hide, application quit, and background playback
**distinct product behaviors** — preserve the current policy; do not invent a
tray feature or stop playback on every window event. For window restoration,
consider disconnected monitors, changed scaling, and off-screen saved bounds;
use the existing window/screen abstractions (`window_manager`,
`screen_retriever`, the desktop window controller under `lib/src/routing/`).

## Verify deployment boundaries only when affected

Check native library bundles and build/packaging configuration for backend
changes. Verify plugin calls are guarded for targets that do not implement
them. Do not broaden network exceptions or permissions to make development
work; make the smallest task-required change the target's documentation
supports.

Use the repository's pinned SDK/toolchain and build entrypoints (`tool/`).
A Linux build does not validate Windows or Apple native code. Do not install
OS toolchains, change signing identities, publish releases, or deploy builds
merely because this workflow lists platform validation — those need the
user's separate authorization.

## Produce an evidence matrix

For each affected target, report: integration path reviewed, tests run,
build result, runtime/device result, and unverified behavior — with explicit
statuses (passed / failed / not run / not applicable). Never turn an
unavailable host or device into a fabricated pass, and do not redesign the
feature to avoid reporting the limitation.

Candidate checks: OS play/pause/seek; metadata after rapid skip; controls
after a window is hidden; graceful exit; background/foreground transition;
native library loading; missing optional desktop service; plugin teardown;
restored window visibility. Choose only checks that bear on the task.
Coordinate queue/engine logic with `music-playback-reliability` rather than
repeating a full playback audit.

## Verification and completion

Run focused tests, `flutter analyze --no-fatal-infos`, and `./tool/check.sh`
for implementation work. For visible behavior, inspect the app-owned PNG
from `POST /v1/presentation/screenshot` via the authenticated diagnostics
API (never AT-SPI, OCR, or window scraping). Report per-target results and
explicitly mark not-run checks with reasons; distinguish mocked logic, host
integration, native builds, and actual device/runtime checks.

## Primary references

- just_audio platform configuration: https://pub.dev/packages/just_audio
- audio_service: https://pub.dev/packages/audio_service
- audio_session: https://pub.dev/packages/audio_session
- Upstream media_kit adapter (the local fork is authoritative):
  https://pub.dev/packages/just_audio_media_kit
