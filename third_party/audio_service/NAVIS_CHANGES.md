# Navis audio_service changes

Based on audio_service 0.18.19 (MIT). The original license and sources are
kept; `example/` and `test/` are dropped. Only the Darwin plugin is changed
(`darwin/audio_service/Sources/audio_service/AudioServicePlugin.m`):

- **Fewer Now Playing updates while playing.** Navis publishes a playback
  state on every libmpv position tick (about 35 a second). macOS and iOS
  extrapolate elapsed time from the playback rate. `setState` republishes
  `nowPlayingInfo` while playing only when the position drifts more than 1 s
  from that extrapolation. Play/pause, speed and media item changes still
  publish at once. With the flood, pausing from Control Center showed the
  position from when playback started (for example 1:00 after 10 s at 1:00)
  for about a second before the paused update landed.
- **Elapsed time before playback state (macOS).** `updateNowPlayingInfo`
  assigns `nowPlayingInfo` before `MPNowPlayingInfoCenter.playbackState`, so
  the system never sees the paused state with a stale elapsed time.

Both were verified by the owner on a macOS release build (2026-11-05). The
system Now Playing state cannot be read by script on macOS 27, so there is no
automated runtime check.
