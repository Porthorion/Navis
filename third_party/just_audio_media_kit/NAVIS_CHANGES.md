# Navis just_audio_media_kit extension

Based on just_audio_media_kit 2.1.0 (Unlicense); original license is retained.

Indexed seeks reset playback readiness before media_kit jumps to the entry.
The deferred-seek helper replaces any previous pending position and omits zero:
a freshly loaded entry starts at zero, so sending an extra seek while mpv is
loading only produces a rejected-command error. Non-zero positions remain
pending until the new entry reports playback initialization or a positive
duration; the previous entry's cached duration cannot authorize a seek.
Seeks without an indexed jump retain their existing behavior. Upstream
media_kit's seek-on-completed behavior in `play()` is unchanged.

`networkInputActive` exposes whether mpv's `cache-speed` is at least 8 KiB/s
(~64 kbps) and its sampled value changed in either direction within the last
two seconds, through the existing `IcyPropertySource.read` → media_kit 1.2.6
`NativePlayer.getProperty(waitForInitialization: false)` bridge. Unsupported,
unavailable, below-floor, stale and released-player reads report false.
Navis samples it no more often than every 250 ms for loading/buffering
progress deadlines; no sidecar or file metadata participates.

The [mpv manual](https://mpv.io/manual/stable/#cache-speed) identifies this as
the network-layer bytes/second estimate also exposed as
`demuxer-cache-state/raw-input-rate`. In mpv's
[stream reader](https://github.com/mpv-player/mpv/blob/v0.41.0/stream/stream.c),
`stream_read_unbuffered` increments `total_unbuffered_read_bytes` on successful
reads; [demux input accounting](https://github.com/mpv-player/mpv/blob/v0.41.0/demux/demux.c)
feeds those bytes to `bytes_per_second`, independently of decoded position and
packet cache size. Range reads therefore contribute before decoding. This is
an estimate, not a cumulative counter: it updates when demux reads return, can
lag in a blocking probe/read, and is unavailable before mpv publishes a demuxer.
Runtime validation must establish coverage of the slow FLAC probe/cold-start
cases; the existing hard cap remains necessary. No media_kit fork, native
polling timer or new dependency was added.
mpv recomputes its smoothed rate about once a second. Unchanged samples between
recomputes remain active for two seconds; falling and rising recomputes both
renew freshness. After input stops, halving decay from 190 KB/s falls below
the floor in about five seconds; a blocked read's stale value expires after
two seconds. The floor stays below real audio rates so steady slow input can
extend loading/buffering without keeping dead input active indefinitely.

Keep upgrades narrow and re-run the vendored adapter fixtures and Navis
playback tests when updating this package.
