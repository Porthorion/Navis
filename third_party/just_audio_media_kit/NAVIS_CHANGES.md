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

ReplayGain (#392 phase 2): the level of a file (signed dB, cut and boost
together) is the `@navis_rg:lavfi=[volume=<dB>dB:precision=float]` stage at the
head of the `af` chain. `MediaKitPlayer._applyAudio` is the one composer of
`af` (`EqualizerChain.withReplayGain`): speed, pitch and EQ edits all go
through it, with the EQ pipeline off too, because media_kit's own `setRate` and
`setPitch` write `af=scaletempo:...` and would drop the stage mid-song. The
`on_load` hook (`configureReplayGainFilter`, next to `configureStartPosition`)
writes the entering file's whole chain synchronously; the level comes from
`ReplayGainLevels` (`src/replay_gain_boost.dart`), a map by `replayGainBoostKey`
seeded from `UriAudioSourceMessage.replayGainDb` in `load`/`insert` and merged
from `setReplayGainLevels` pushes, so a natural join, a jump and a seek are the
same lookup and an unknown key is 0 dB. Only a `live` push moves the playing
file: `af-command navis_rg volume <dB>dB volume` (the 4th argument is required),
then an `af` write, since mpv rebuilds the chain from `af` on any seek; without
`af-command` (macOS libmpv 0.36) the `af` write alone lands the value. The
global `volume-gain` is never set. `commandSync` and `setPropertySync` are
injectable like `positionReader`.
