# Transcode offset seek (1.5.1)

Ledger: Porthorion/Navis #86, item 2 of the 2026-10-20 hand-off. Branch
`fix/transcode-offset-seek` from `release/1.5`; PR into `release/1.5`.

## Problem

On a linear transcode (Navidrome `200`, `Accept-Ranges: none`, unknown length)
a seek past what is local cannot be served natively:

- Android waits up to `seekProgress` (45 s) for the lock-cache download to
  complete, then reloads from the completed file. Otherwise the seek fails.
  The lock-cache branch is `_seekWithRecovery` →
  `_waitForCompletedLockCache` in `navis_audio_handler_recovery.dart`.
- Desktop (direct HTTPS through mpv, plus a sidecar download) seeks linearly
  and slowly, then fails. The baseline was 12 s + 12 s.

The owner sees "seek snaps back" on Opus over both cellular and Wi-Fi.

`timeOffset` is verified on the live server (#86, 2026-10-19). Opus, MP3 and
AAC streams start at the offset, and the first byte arrives in 0.9–2.2 s.

## Design

The hybrid design: a completed local cache wins. Otherwise a transcode seek
reopens `stream.view` with `timeOffset=<whole seconds>`. The download of the
full file keeps running beside it.

There is **one translation layer, in the vendored just_audio `AudioPlayer`**,
so every app consumer stays unchanged. An offset stream reports time from 0. The
source carries `positionOffset`. `AudioPlayer` adds it to everything it reads
from the platform and subtracts it from everything it sends. `position`,
`positionStream`, `bufferedPosition`, `duration`, `playbackEvent.updatePosition`
(the desktop seek settlement), persistence, scrobbling, lyrics, MPRIS/SMTC and
crossfade timing all see song time without any change.

Reject a handler-side translation layer: it means about 60 read sites (see
the survey summary at the end).

## Reuse first (existing infrastructure to build on)

- Stream URL: `SubsonicApiClient.streamUrl` (`lib/src/api/subsonic_api_client.dart` ~557).
- Capabilities: `ServerCapabilities.extensions`
  (`lib/src/api/models/server_capabilities.dart`). It is already stored in
  `server_config.capabilities` by the login probe. Reuse the JSON parsing in
  `adaptive_library_sync_coordinator.dart` ~379 rather than adding a new probe.
- Source resolution: `PlaybackSourceResolver` and `ResolvedPlaybackSource.directStream`,
  including the desktop sidecar branch (`playback_source_resolver.dart` ~265).
- Reload at a position: the existing direct-stream reload used by seek
  recovery, `_replaceQueuePhase1(initialPosition:, preferLockCaching: false)`
  (via `_rebuildQueueForSeekRecovery`). Do not write a second reload pipeline.
- The seek lane, `_PendingSeek` and the seek trace/diagnostics already
  serialise and log seeks. Add to them; do not add a parallel mechanism.
- Download continuity already holds. Android `_cancelStaleLockCacheDownloads`
  skips the current song. The desktop `RollingCacheSidecarDownloader.start`
  returns early for the same songId and path.

## Items (test first, one commit each)

### 1. `streamUrl` timeOffset
- Add `int? timeOffsetSeconds` to `streamUrl`. Emit `timeOffset` only when it
  is greater than 0. Do not send `estimateContentLength` with it.
- Failing test first in `test/src/api/subsonic_api_client_test.dart`.
- `download_service.dart` must not change.

### 2. Capability
- Add `bool get supportsTranscodeOffset` on `ServerCapabilities`: true when an
  extension is named `transcodeOffset`.
- Add `readSupportsTranscodeOffset` to `PlaybackSourceResolver` (default false),
  wired in `app_providers.dart` ~1357 from the active server config's stored
  capabilities.
- Tests: the model getter, and that the resolver default is off.

### 3. just_audio translation layer (`third_party/just_audio/lib/just_audio.dart`)
- Add `final Duration positionOffset` (default `Duration.zero`) to
  `UriAudioSource` / `ProgressiveAudioSource` and the `AudioSource.uri`
  factory. Navis's clone helper (`asClonedAudioSource`) must preserve it.
- Offset of the current item = `positionOffset` of the sequence item at the
  event's `currentIndex`, or zero.
- **Inbound, at the single platform-event ingestion point** (~1620, where a
  `PlaybackEventMessage` becomes a `PlaybackEvent`): add the offset to
  `updatePosition` and `bufferedPosition`, and to `duration` when it is not
  null. The optimistic writes in play/pause/setSpeed/setPitch/seek reuse
  `position`, which is already song time, so they need no change.
- **Outbound:** `seek(position)` sends `position - offset` to the platform when
  the target index is the offset item. If that would be negative, send zero.
  The handler never asks for this (see item 5).
- The load or `setAudioSources(initialPosition:)` path subtracts the initial
  item's offset. Check `_pluginLoadRequest` / `resetInitialSeekValues` too.
- Check the tracked `just_audio_media_kit` adapter for its own position
  bookkeeping that bypasses the platform events: the deferred seek covered by
  `test/src/third_party/mediakit_seek_test.dart`.
- Tests in `test/src/third_party/` with the existing fake platforms (the
  `_ProxyPlayer` / `_NativePlayer` patterns):
  - inbound translation of position, buffered and duration;
  - seek subtraction;
  - an auto-advance to the next item gives offset 0;
  - initialPosition is subtracted;
  - an offset of zero leaves behaviour exactly as today.

### 4. Resolver: offset source
- Thread an optional `Duration? transcodeOffset` through
  `_prepareSingleItem` / the resolver, for the **start item only**.
- With an offset greater than 0 it returns `directStream` with
  `uri = streamUrl(..., timeOffsetSeconds)` and `positionOffset` set. It never
  uses LockCaching, and the offset stream never feeds rolling-cache bytes.
- Desktop: keep `sidecarCacheFilePath`. The sidecar's remembered stream URI
  (`_rememberSidecarSong`, queue_loading ~712) **must be the full, non-offset
  URI**. Otherwise the sidecar stores a file that starts at T as the full
  song, which corrupts the cache. This is the highest-risk line in the
  change; test it explicitly.
- Tests in `playback_source_resolver_test.dart`.

### 5. Handler seek branch (`_seekWithRecovery`, recovery.dart ~63)
Add a branch before the existing lock-cache and native branches.
`_shouldSeekViaTranscodeOffset(target)` is true when all of these hold:
- the song is not radio and is a remote stream (`lockCachedStream` or `directStream`);
- it was resolved with a transcode quality (format or maxBitRate set; never original);
- the server supports `transcodeOffset`;
- `_completedCacheFileFor` the song is null;
- and one of these:
  - Android lock-cache: `!await _lockCacheServesRanges`;
  - desktop direct stream;
  - the current source already has an offset greater than 0.

Then `_seekViaTranscodeOffset(target)`:
- T = target floored to whole seconds, clamped to [0, duration − 1 s].
- If T < 1 s, reload without an offset: the normal source from 0.
- Otherwise reuse the seek-recovery reload (`_replaceQueuePhase1` /
  `_rebuildQueueForSeekRecovery` path) with `transcodeOffset: T` and
  `initialPosition: T`. just_audio subtracts the offset, so playback starts at
  native 0.
- Keep the playing/paused state.
- Cancel an active crossfade first, as other reloads do.
- Every seek on an offset source (forward, backward, to 0) goes through this
  branch, because the offset stream is linear too.
- On failure, fall back to the existing path (cache wait / completed file).
  Never leave playback stopped (silent self-healing policy).
- Without the capability, behaviour is exactly as today.
- Log the seek path as `transcodeOffset` in the existing seek trace, and
  expose `positionOffsetMs` in the existing diagnostics snapshot so
  `tool/live_seek_stress.py` can assert it.

### 6. Edge cases (each one is a handler test in `navis_audio_handler_navigation_test.dart`, using `_ControllableAudioPlayer` / `playerFactory`)
1. A seek during an in-flight offset reload: the latest seek wins (seek-lane
   semantics). One reload, at the newest T.
2. Natural end of an offset stream advances to the next song. **No replay of
   the same song** (#86's bug class).
3. Repeat-one on an offset source: the native loop would restart at T. On
   loop or auto-advance to the same index, reload the song from 0 without an
   offset.
4. Previous (restart when more than 3 s in) goes to seek(0), which reloads
   without an offset.
5. The scrobble session is not restarted by an offset reload.
6. The desktop sidecar is not cancelled or restarted with an offset URI.
7. Android: the original lock-cache download keeps running. Once it
   completes, the next seek uses the completed file instead of an offset.
8. A server without the capability, or original quality: no `timeOffset` ever appears in a URI.

Known corner: landing up to 1 s before the target (whole-second `timeOffset`).
Document it; do not add a native sub-second seek, because the stream is linear.

### 7. Docs
- Replace the "Deferred: transcode-offset seeking" paragraph in
  `docs/architecture.md` (~4897) with the shipped behaviour.
- Add a 1.5.1 changelog line, following AGENTS.md / changelog conventions.

## Done when
- All new tests are written first and pass; `./tool/check.sh` is green (run
  under the host memory cap, one heavy job at a time).
- Runtime pass (orchestrator, separately): `tool/live_seek_stress.py`
  seek_far / seek_back / natural-end cases on the live server, Opus 128, with
  wan6000 and 1.5 Mbit/s throttles, on Linux and the Android emulator. Expect:
  the seek lands in 3 s or less, within 1.5 s of the target, with no
  snap-back, and the next song follows with no replay.

## Survey summary (2026-10-20)
App position reads by file:
- media_session: 24
- recovery: 19
- crossfade: 5
- navigation: 4
- persistence: 2
- queue_loading: 1
- bootstrap: 1
- UI consumers: 7, all through `handler.positionStream` /
  `PlaybackSnapshot.duration` (metadata-first via `resolveEffectivePlaybackDuration`).

The only direct `PlaybackEvent.updatePosition` read is recovery ~193, the
desktop seek settlement.
