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

`LockCachingAudioSource.prefetch()` starts (or joins) the whole-file download
without creating a response, so no in-progress replay buffer holds the body; a
later `request()` shares the same download. Navis warms the next song with it.
`isDownloading` reports whether the whole-file download is running, which the
warm uses to notice a download that died mid-body.

`LockCachingAudioSource.downloadedBytes` exposes the current download's
in-memory byte count. `downloadProgressStream` emits on every body chunk,
including repeated whole-percent values for sub-percent or unknown-length
transfers. Navis uses those events for player-side progress deadlines without
polling partial-file metadata. The completion value remains reserved for the
flushed, published cache file.

The stream proxy closes range requests whose response has no known content
length with HTTP 500 instead of dereferencing null while constructing
`Content-Range`. Navis can then recover the remote source; completed cache reads
still provide sized ranges.

The stream proxy restores chunked framing for unknown-length bodies and
explicitly sends `Content-Length: 0` for empty HTTP 500 responses (#86). It
owns each local socket from acceptance, monitoring its read side independently
of origin headers or body activity. A disconnect cancels only that request's
pending/live origin range. Request-scoped cancellation follows virtual
`StreamAudioSource.request` overrides through a Dart zone without changing the
public API. Proxy shutdown closes its detached sockets. A range cancelled
before its returned stream is listened to never subscribes to the closed origin.
Sized and chunked responses use `Connection: close`; raw header field values
retain `HttpHeaders` validation and sized bodies retain length checks.

Lock-cache origin disconnects and the existing 30-second body-progress timeout
discard partial files and fail in-progress response streams. The stream proxy
uses `Socket.addStream` to propagate errors and destroys the connection without
sending a terminating chunk instead of publishing clean EOF (#86). The URI/header
proxy also aborts body errors, including short sized responses, without retrying them
as HTTP/0.9. Its raw HTTP/0.9 fallback destroys both sockets on read errors;
normal EOF remains valid for that unframed protocol. Complete bodies still
close cleanly, and radio retains native retries and no added body timeout.
Fixtures verify partial delivery, client errors, cache cleanup, fresh fetches,
and clean live-stream completion. A JVM fixture reads an incomplete chunked
body and verifies its `IOException` selects the existing fatal load policy.

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

Android progressive HTTP Repeat One and Repeat All playlists containing a
progressive HTTP source keep the requested Dart loop mode but use native
repeat-off. Pause-at-end applies to the current item for owned One and only
the last item for owned All. The end-of-item PlayWhenReady reason (and an
idempotent ENDED fallback) restarts the same occurrence for One or wraps to
index zero for All, preserving Play/Pause intent without terminal completion.
Its timeline window UID survives appends, inserts and moves while current;
removal/replacement cannot restart a different occurrence. A revision cancels
pending restarts on transport and selection/source replacement.

Mode changes retain a captured boundary and apply the latest mode when it is
consumed. An end-of-item reason also arms recovery when an app-thread mode
change or root-playlist removal cleared the pause-policy UID before native
PlayWhenReady became false. A current window UID is still required; an empty
timeline publishes completion instead of capturing an invalid boundary.
ENDED with Play requested and native playback paused
shares that recovery. Native ownership is recomputed from current playlist tags
before resuming, including when the last eligible stream was removed. An in-item
seek re-arms pause policy after seeking. Off releases a non-last pause without
restarting the song (advancing if already ENDED), while the true end publishes
completion without re-arming. Stale ENDED callbacks cannot publish completion
while Play is requested and native state has already moved on, including on
file-only queues; late end reasons cannot re-arm a resumed boundary.

Known limits: Pause/Play before the native boundary signal can advance under
Repeat One, and a seek before a delayed end reason can still be overwritten by
a restart at zero. Existing app-visible state cannot distinguish these from
ordinary in-item Pause/Play or a fresh EOF after seeking.
This prevents Media3 1.4.1 from preloading another occurrence of a linear
stream and silently rewinding its current period when a later request becomes
seekable (#86). File-only playlists, HLS/DASH and radio's existing default-retry
opt-out retain native repeat; owned One loses its gapless restart and owned All
loses the gapless queue wrap.
`ProgressiveRepeatTest` covers policy and restart decisions in the existing JVM
harness; `JustAudioRepeatBoundaryTest` exercises the real bridge's policy,
playlist tag scan and posted action using the existing reflection/proxy JVM
fixtures, with the posted callback driven directly instead of an Android Looper.
`JustAudioRepeatCallbackTest` drives production scheduling, timeline and item
transition listeners, distinct occurrence UIDs and ExoPlayer-style callback
order. It captures the missing-Handler post boundary and runs the guarded action;
it does not run an Android Looper or the posted lambda itself.
The pairwise Dart loop detector now also recognizes unknown-duration
plain-stream backwards jumps; tail/zero/buffering/ready fixtures cover middle
and last items with and without offsets. Navis's existing offset handler and
crossfade controller remain the sole Dart owners of offset reloads and fades.
