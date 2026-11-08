# Navis platform-interface extension

Based on just_audio_platform_interface 4.6.0 (MIT). Adds optional initial EQ
configuration, typed filters, player-scoped configuration application, and
observable processing status. Existing backend implementations retain their
default unsupported methods until they explicitly implement EQ.

Navis raises the local Dart lower bound to 3.4 for shared response mathematics
using records and switch expressions. Typed validation/coefficient/headroom
calculations are also used by the Linux mpv chain compiler.

`ProgressiveAudioSourceOptionsMessage.androidUseDefaultLoadErrorHandling`
serializes the radio opt-out from Navis's Android unknown-length VOD retry
policy. It defaults to false; other platform adapters ignore the option.

`AudioPlayerPlatform.setReplayGainBoost` carries Navis's ReplayGain boost
(positive gain): the playing song's boost and a per-URI map for backends that
switch gain per file. The default throws `UnimplementedError`, which the app
reads as "no boost stage here".

`EqualizerStateMessage` adds `boostRequestedDb`, `boostAppliedDb` and
`boostClipSamples` (all default 0), read from the Android processor's state.

`SetReplayGainBoostRequest.index` is the queue index the boost was computed for;
a backend that knows which song it plays ignores a non-zero value for another
index.

`EqualizerStateMessage` also carries the optional Darwin-only `processedFrames`
and `levelDeltaDb` diagnostics.

`EqualizerStateMessage` also carries the optional Darwin-only pitch stage
diagnostics `pitchCents`, `pitchActive`, `pitchLatencyFrames`,
`pitchResetCount`, `pitchInputHz`, `pitchOutputHz`, `pitchPullMismatches` and `pitchReason` (I21). `setPitch` itself
is unchanged.

`EqualizerStateMessage` also carries the optional Darwin-only `formatStreams`
(a list of the new `EqualizerFormatStreamMessage`: `sampleRate`, `channels`,
`processedFrames`, `levelDeltaDb`), `unmatchedFrames` and `overlapBlocks` (I25):
the tap keeps one equalizer stream per audio format of the queue; and
`livePipelines`, `prepareCalls`, `unprepareCalls` and `clampedUnprepares`, the
balance of the pipelines that prepared the tap.

`UriAudioSourceMessage.replayGainDb` (progressive, DASH, HLS) is a song's
signed in-pipeline ReplayGain. `AudioPlayerPlatform.setReplayGainLevels`
(`SetReplayGainLevelsRequest`: `byId`, `byUri`, `live`) updates it later; the
default does nothing and the method channel ignores `MissingPluginException`,
so a backend without the stage never fails playback.

