# Navis audio_service changes

Based on audio_service 0.18.19 (MIT). The original license and sources are
kept; `example/` and `test/` are dropped. Only the Darwin plugin is changed
(`darwin/audio_service/Sources/audio_service/AudioServicePlugin.m`):

- **Fewer Now Playing updates while playing.** Navis publishes a playback
  state on every libmpv position tick (about 35 a second). The system
  extrapolates elapsed time from the published rate. While playing,
  `setState` keeps the last published elapsed time, timestamp and rate and
  republishes only when the app's position differs from the system's
  extrapolation by more than 100 ms (`kNowPlayingDriftMs`). That catches
  seeks, stalls and speed changes larger than 100 ms (Control Center shows
  whole seconds), and keeps the system clock within 100 ms. The published
  time is the native assignment time, matching how the system stamps it. Play/pause, speed and processing-state changes always publish.
  `updateNowPlayingInfo` always reassigns `nowPlayingInfo`, so a correction
  back to the last published value is not deduplicated away. `stopService`
  clears the cached entry, and a later idle state does not bring it back. With the flood, pausing from Control Center showed
  the position from when playback started (for example 1:00 after 10 s at 1:00)
  for about a second before the paused update landed.
- **Default playback rate is 1.0.** `MPNowPlayingInfoPropertyDefaultPlaybackRate`
  is always 1.0 (Apple: the normal rate) instead of the current speed while
  playing and 0 when paused. `PlaybackRate` still carries the speed (0 when
  paused) and the drift check above still uses it. With the Dart handler
  publishing track time on macOS, the system extrapolates the elapsed time with
  that rate, so Control Center matches the app at non-1x speeds.
- **Elapsed time before playback state (macOS).** `updateNowPlayingInfo`
  assigns `nowPlayingInfo` before `MPNowPlayingInfoCenter.playbackState`, so
  the system never sees the paused state with a stale elapsed time.

The pause fix was verified by the owner on a macOS release build (2026-11-05). The drift arithmetic was checked in a standalone simulation: steady playback publishes about once a minute, a stall stays within 100 ms, and a 120 ms seek is corrected at once. The rate stays at the playing speed while buffering (as upstream), so a stall is bounded rather than exact; a rate of 0 there would flicker the iOS lock-screen play button. The
system Now Playing state cannot be read by script on macOS 27, so there is no
automated runtime check.
