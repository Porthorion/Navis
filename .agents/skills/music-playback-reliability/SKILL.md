---
name: music-playback-reliability
description: Navis playback, queue, and audio-engine reliability — just_audio/audio_service/audio_session behavior, queue occurrence identity, seek and stream resume, stale async callbacks, audio focus, and the vendored media_kit backend. Use for any player, queue, shuffle/repeat, seeking, background playback, or OS-media-control bug, even a vague "playback is flaky".
metadata:
  author: ChatGPT
  version: '2.1'
  project: Navis
  origin: custom-not-official
  prepared: '2026-09-22'
  adapted: trimmed duplicated policy boilerplate, anchored to repo paths
---

# Navis Music Playback Reliability

Task-scoped workflow for playback work. AGENTS.md and
`docs/development/agentic-engineering.md` are always loaded and govern scope, review, and
validation; this skill adds the playback-specific constraints.

## Ground rules

Read the playback section of `docs/architecture.md` before touching playback,
cache, or audio code — the source priority **permanent download → rolling
cache → direct stream** is a non-negotiable contract. Inspect the actual
implementation under `lib/src/features/player/` (data/domain/presentation),
its callers, and its tests before editing. Use `pubspec.yaml` as declared
intent and `pubspec.lock` for resolved versions; do not replace or "upgrade"
dependencies as cleanup.

## Map the actual audio path

Declared: just_audio ^0.10.6, audio_service ^0.18.19, audio_session ^0.2.4,
rxdart, desktop media_kit libraries, plus two vendored packages:

- `third_party/just_audio_media_kit` — carries a documented libmpv
  force-seekable customization for Subsonic progressive streams. Never replace
  with the hosted version or strip the customization as cleanup.
- `third_party/navis_windows_smtc` — the Windows SMTC adapter; read its
  actual integration before concluding anything about Windows media controls.

Establish which backend each target really uses by reading initialization and
platform guards, not by inference from the manifest. Desktop media-kit
initializes on Linux, Windows, and macOS; debug macOS skips it unless
`NAVIS_ENABLE_MEDIA_KIT_DEBUG=true`. Trace UI and system-media commands
through the controller/handler → player → event streams → queue authority →
persistence → UI/system metadata. Record ownership of players,
subscriptions, timers, and long-lived services: shared playback lifetime must
stay independent of the now-playing screen's visibility.

## Preserve playback semantics

Define the relevant transitions before editing: current queue occurrence,
order, requested play/pause state, processing state, position, repeat/shuffle
policy, failure policy.

- **Occurrence identity:** distinguish a track ID from an occurrence in the
  queue; duplicates may be intentional. Preserve occurrence identity through
  reorder and removal. Do not invent new shuffle, end-of-queue, resume, or
  crossfade behavior.
- **State granularity:** just_audio exposes `playing` and `processingState`
  separately. Do not collapse buffering/loading/ready/completed/paused-intent/
  errors into one boolean. Check the installed API contract before awaiting
  `play()` — do not block later transport commands behind a Future that only
  completes when playback finishes or is interrupted.
- **Stream resume:** for stream-source tasks, check authentication handling,
  expired source credentials, server byte-range behavior, transcoding, unknown
  duration, and the vendored progressive-seek customization. Preserve the
  source/quality identity that makes a resumed stream compatible; an arbitrary
  byte offset is not valid after transcoding changes.

## Check races and lifecycle boundaries

Use the project's sequencing/cancellation mechanism to reject old source
loads, seeks, metadata requests, artwork, and queue events after a newer
command, account switch, or player replacement. A canceled Dart operation is
not proof that all native events stopped — prevent stale events from moving
the wrong track's position or system metadata.

Inspect existing automatic interruption handling before adding manual
audio_session logic; avoid duplicate pause/resume/duck actions. Preserve
user-paused intent across interruptions, route changes, and reconnects.
Clean up subscriptions/timers at the actual owner's lifetime boundary — never
dispose a shared player when a screen closes. Keep credential-bearing media
URLs out of logs and fixtures.

## Regression coverage and verification

Candidate cases: skip while loading; two loads finishing in reverse order;
seek while buffering; repeated queue occurrences; removing the current item;
completion at queue end; stale artwork; request errors; old-account
callbacks; interruptions while already paused. Use controllable fakes for
logic; place tests under `test/src/features/player/` mirroring the source
layout (see the `dart-add-unit-test` skill for harness patterns).

Playback is runtime-affecting: widget tests and fakes are insufficient for
handoff. Follow the isolated-profile runtime loop and authenticated
diagnostics API in `docs/development/development-workflow.md`, then `./tool/check.sh`.
A fake-player test passing is not proof of audible output, native seeking,
gapless behavior, background playback, or OS controls — report those
separately, and coordinate native integration with
`navis-platform-integration` rather than assuming one host covers all five
targets.

## Primary references

Prefer installed-version docs and local source when they differ from these:

- just_audio: https://pub.dev/packages/just_audio
- audio_service: https://pub.dev/packages/audio_service
- audio_session: https://pub.dev/packages/audio_session
- Upstream just_audio_media_kit (the local fork is authoritative):
  https://pub.dev/packages/just_audio_media_kit
