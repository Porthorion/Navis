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

Keep upgrades narrow and re-run the vendored adapter fixtures and Navis
playback tests when updating this package.

ReplayGain boost (positive gain): `setReplayGainBoost` keeps a per-URI boost
map and an `on_load` hook (`configureReplayGainBoost`, next to
`configureStartPosition`) sets mpv's file-local `volume-gain` from it, so the
gain ends with the file. mpv applies `volume-gain` to audio it has already
queued, so a natural join starts at `min(previous, own)` and is held (may only go
down) until it has played 0.5 s (`ReplayGainBoostState`,
`src/replay_gain_boost.dart`); load, indexed seeks and removing the playing
entry are explicit switches, tied to the playlist position they load. Gain
writes are synchronous. The global
`volume-gain` is never set.

`ReplayGainBoostState` measures the lifetime of an expected switch on a
monotonic `Stopwatch` instead of the wall clock, and no longer has the unused
`cancelSwitch()`.
