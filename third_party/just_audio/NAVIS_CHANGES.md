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

Keep upgrades narrow and re-run the native response/lifecycle fixtures and
Navis playback tests when updating either vendored package.
