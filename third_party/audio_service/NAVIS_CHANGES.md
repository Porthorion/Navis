# Navis audio_service changes

Based on audio_service 0.18.19 (MIT). The original license and sources are
kept; `example/` and `test/` are dropped. Only the Darwin plugin is changed
(`darwin/audio_service/Sources/audio_service/AudioServicePlugin.m`):

- **Fewer Now Playing updates while playing.** Navis publishes a playback
  state on every libmpv position tick (about 35 a second). The system
  extrapolates elapsed time from the published rate. While playing,
  `setState` keeps the last published elapsed time, timestamp and rate and
  republishes only when the app's position differs from the system's
  extrapolation by more than 250 ms (`kNowPlayingDriftMs`). That catches
  seeks, stalls and speed changes, and leaves the system clock at most 250 ms
  out. Play/pause, speed and processing-state changes always publish.
  `updateNowPlayingInfo` always reassigns `nowPlayingInfo`, so a correction
  back to the last published value is not deduplicated away. `stopService`
  clears the cached entry. With the flood, pausing from Control Center showed
  the position from when playback started (for example 1:00 after 10 s at 1:00)
  for about a second before the paused update landed.
- **Elapsed time before playback state (macOS).** `updateNowPlayingInfo`
  assigns `nowPlayingInfo` before `MPNowPlayingInfoCenter.playbackState`, so
  the system never sees the paused state with a stale elapsed time.

The pause fix was verified by the owner on a macOS release build (2026-11-05). The drift arithmetic was checked in a standalone simulation: steady playback 1 publish per minute, an 8 s stall stays within 250 ms, and a 0.9 s seek is corrected at once. The
system Now Playing state cannot be read by script on macOS 27, so there is no
automated runtime check.
