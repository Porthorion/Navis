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
same lookup and an unknown key is 0 dB. The hook also reads `playlist-pos` and
looks the level up by the entry's source id (the adapter mirrors the ids through
load, insert, move and remove), so one file queued at two positions keeps two
levels; the URI key is only the fallback. Only a `live` push moves the playing
file: `af-command navis_rg volume <dB>dB volume` (the 4th argument is required),
then an `af` write, since mpv rebuilds the chain from `af` on any seek; if
`af-command` fails the `af` write alone lands the value (logged). Without the
EQ pipeline at 1x the chain is the stage alone (no tempo). The global
`volume-gain` is never set. `commandSync` and `setPropertySync` are injectable
like `positionReader`. The stage is on for every platform, macOS included (#490:
libmpv 0.41 verified); `replayGainFilter: false` is injectable for tests and
keeps the pre-phase-2 adapter (no stage in `af`, no hook, levels ignored,
media_kit's own `setRate`/`setPitch` while the EQ pipeline is off).

Peak limiter (#846 phase 5): a boosted level (`db > 0`) ends the chain with the
byte-constant `EqualizerChain.limiterStage` (`@navis_lim:lavfi=[alimiter=
limit=0.891:level=0:attack=5:release=100:latency=1]`, -1 dBFS; `level=0` and
`latency=1` are mandatory), after `@navis_rg` and `@navis_eq`; cuts never get
it. It is structural: `withReplayGain(db, limiterSupported:)` appends it, there
is no player-wide flag. mpv accepts a bad `lavfi=[...]` graph and only drops
the file at audio init, so the adapter probes once, idle, at `ready()` (before
any load): `EqualizerChain.probeLimiter` writes `@navis_probe:lavfi-alimiter`
to `af` and clears it. The wrapper form checks the filter name while parsing,
so a libmpv without `alimiter` (bundled Windows and macOS until rebuilt)
answers false and Loud keeps the peak-capped behaviour; there is no "unknown"
state (`limiterSupported:` is injectable). A live push that adds the limiter
(the playing level was <= 0) skips `af-command` and writes `af` alone. A
rejected `af` write that carried the limiter (hook, live push or edit) is
written once more at no boost (min(gain, 0 dB)) and without it; only when that
lands is the limiter turned off for that player, for good, and every later
boost it plays is clamped to 0 dB. A retry that fails too was not the limiter:
the limiter stays on, and a live push whose `af` writes both failed leaves the
playing level at what mpv still holds, so the next push is judged against the
chain mpv really runs (`MediaKitPlayer.limiterSupported`,
`JustAudioMediaKit.replayGainLimiterSupported`).
The hook callback of `configureReplayGainFilter` now does the write itself.

