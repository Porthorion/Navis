# Navis just_audio extension

Based on just_audio 0.10.6 (MIT); original license and platform sources are
retained. The matching 4.6.0 platform interface is vendored separately.

Navis adds a typed, player-scoped parametric EQ configuration and status API.
Configurations are retained across idle/native player transitions. Android
installs a Media3 PCM processor after the existing silence/speed processors,
with independent filter history per output channel. Configurations cross from
the control thread to the processing thread at audio-block boundaries.

This extension does not replace Media3, audio_service, source loading, audio
focus, media sessions, or the Apple playback backend. Other backends may
implement the extension; unimplemented calls fail explicitly. Original system
audio effects remain available to upstream callers, but Navis retires their
experimental EQ/loudness UI and uses its own processing path.

`LockCachingAudioSource.originSupportsRangeRequests` exposes whether the
origin's download response advertised byte ranges (null until it arrives).
Navis uses it to decide whether a seek beyond the downloaded bytes can be
served natively (the source then issues its own Range request) or must wait for
the completed cache file, as for a server transcode streamed linearly.

`LockCachingAudioSource.cancelDownload()` stops a download in progress: pending
and in-progress responses fail, the partial file is discarded and the next
request starts over. Navis cancels downloads of songs the player has moved on
from, which otherwise ran to completion and starved the current song on a slow
link.

The stream proxy closes range requests whose response has no known content
length with HTTP 500 instead of dereferencing null while constructing
`Content-Range`. Navis can then recover the remote source; completed cache reads
still provide sized ranges.

The stream proxy restores chunked framing for unknown-length bodies and explicitly sends `Content-Length: 0` for empty HTTP 500 responses after clearing headers (#86).

Keep upgrades narrow and re-run the native response/lifecycle fixtures and
Navis playback tests when updating either vendored package.

Android source errors report Media3's `PlaybackException.errorCode` (for
example 2001 for a failed connection, 2005 for a missing file) instead of the
coarse `ExoPlaybackException.type`, and a bad HTTP status appends
` (HTTP <status>)` to the error message. Navis uses both to tell a dead radio
station from a network failure.

`AudioPlayer.play()` abandons a denied audio-focus request and asks again up
to three times, then throws `AudioFocusDeniedException`; Pause, Stop and
disposal cancel a pending request. It reports `playing` only once focus is
granted. A
load that runs while focus is pending therefore cannot start native playback
through the implicit play path, and a denied request never publishes a
transient playing state.

`UriAudioSource.positionOffset` (also `AudioSource.uri(positionOffset:)`) marks a
stream that starts that far into the song, as a server transcode opened with
`timeOffset`. The platform reports time from zero. `AudioPlayer` adds the offset
of the item at the event's `currentIndex` to `updatePosition`, `bufferedPosition`
and a non-null `duration` where a platform event becomes a `PlaybackEvent`, and
subtracts it from `seek` positions, the `load` initial position and the idle
platform's reported duration (clamped at zero). Every position the app reads is
therefore song time, and an auto-advance to an item without an offset reads
from its own zero. Platform adapters see platform time only.

The loop detector behind `positionDiscontinuityStream` judges an offset item in
platform time: `positionOffset` is subtracted from the interpolated previous
position, the current position and the duration before the heuristics, so a
native loop that restarts the stream at its own start is reported as an
`autoAdvance` discontinuity even when the platform emits only sparse events
(ExoPlayer). For an unknown duration an offset item needs the position to drop
by a second; an item without an offset behaves as before.

While a playlist edit (insert, add, remove, move, clear) is in flight, a
platform event that carries the previous event's index is translated with the
previous event's item, not the item the Dart sequence now holds at that index:
the platform only reports the shifted index once it has applied the edit. Its
duration is stored on that item too. Without offsets the only change is that
the stored duration lands on the right item during such a window.

Android progressive loads use a `DefaultLoadErrorHandlingPolicy` override to
make unknown-length HTTP response errors fatal (`C.TIME_UNSET`), handing them
to Navis's existing position-preserving recovery. Media3 1.4.1's live-stream
retry would otherwise reset a chunked VOD stream to byte zero. The decision
uses `LoadErrorInfo.loadEventInfo.responseHeaders` and `dataSpec.length`;
valid `Content-Length` or sized `Content-Range`, bounded requests, non-HTTP
sources, and connection failures without response headers retain the default
policy. `ProgressiveAudioSourceOptions.androidUseDefaultLoadErrorHandling`
opts radio initial loads and reconnects into the unchanged native policy.
`AudioSource.uri(options:)` forwards the option only for progressive sources.
The matching platform interface serializes this source option. No HTTP timeout
or HLS/DASH policy changes are made. `ProgressiveLoadRetryTest` supplies pure
JVM framing fixtures using the existing `EqualizerDspTest` executable pattern.

Android progressive HTTP repeat-one keeps the requested Dart loop mode but
uses native repeat-off plus pause-at-end. The end-of-item PlayWhenReady reason
(and an idempotent ENDED fallback) restarts the same index at zero, preserving
Play/Pause intent without publishing terminal completion. A revision cancels
pending restarts on transport, selection/source/playlist or loop-mode changes.
This prevents Media3 1.4.1 from preloading the same linear stream and silently
rewinding the current period when the repeated request becomes seekable (#86).
Local files/assets, HLS/DASH, radio's existing default-retry opt-out and all
repeat-all behavior remain native; HTTP repeat-one loses gapless restart.
`ProgressiveRepeatTest` covers policy and restart decisions in the existing JVM
harness. The pairwise Dart loop detector now also recognizes unknown-duration
plain-stream backwards jumps; tail/zero/buffering/ready fixtures cover middle
and last items with and without offsets. Navis's existing offset handler and
crossfade controller remain the sole Dart owners of offset reloads and fades.
