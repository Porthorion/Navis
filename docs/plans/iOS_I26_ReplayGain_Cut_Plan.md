# I26 phase A: the iOS ReplayGain cut moves to each item's audio mix

Base: `dev` @ ee27b6c9. Scope: cut only (dB <= 0). Boost, Android and mpv code paths do not change.
Native = `third_party/just_audio/darwin/just_audio/Sources/just_audio/`; Dart = `lib/src/features/player/data/`.

## 1. Decision: iOS joins `replayGainInPipeline`; levels and boost both go out
Every stamp, push, `live` and Smart-adoption site is already gated on one getter, so changing that getter is the smallest change.
- `navis_playback_rules.dart:83-88`: `navisReplayGainInPipeline({usesMpv, androidProcessor=false, iosTap=false}) => usesMpv || androidProcessor || iosTap`. Rewrite the doc comment at :76-82; it currently says "False on iOS".
- `navis_audio_handler.dart:834-839`: pass `iosTap: _usesIos && _equalizerPipelineEnabled`, the same expression as the boost rule at :845. Rewrite the comment at :824-831.
- `media_session.dart:846-876`, `_sendReplayGainLevelsTo`: when in-pipeline, push the levels. Then, only if `_usesIos`, also run the existing boost-map body. Move that body unchanged into `_sendReplayGainBoostTo(player)`. Catch each send separately so that one failure cannot stop the other.
- Native `setReplayGainLevels` always replies `result(@{})`. Today it falls to `FlutterMethodNotImplemented` (AudioPlayer.m:227). Once it is implemented, an error would surface as a PlatformException, which Dart does not swallow.
- After this change, on iOS with the tap: sources are stamped with `replayGainDb` (`_withReplayGain` media_session:789-800, plus queue_editing:81, queue_loading:1160, handler:1146, crossfade:533/806/888/915, recovery:1096). `_replayGainVolumeFor` (:729-741) returns `_baseVolumeFor()`. Settings changes push `live` (applyRuntimeSettings handler:2596 calls `_applyReplayGainVolume(live: true)`). A tag refresh (queue_editing:759-793) pushes non-live, which matches D7.
- Intended side effect on the boost: Smart now freezes the heard song's pair from `_pushedSmartNeighbours` (media_session:698, :1061), so the cut and the boost use the same pair. The boost code itself is unchanged. If an iOS boost expectation in a Smart row moves, this is where it moves.
- Required fix: the iOS phase-1 successor (`_gaplessNextSong`, queue_loading:1048) is stamped by `_prepareSingleItemForQueueFill` (queue_loading:995) with no play order. Its Smart neighbours then come from the old `_queueItems`, and a non-live push never corrects an item that is already heard. Fix: after `nextItem` resolves (around :1239), call `if (replayGainInPipeline && nextItem != null) _stampReplayGainFor([nextItem], [for (s in songs) s.albumId], at: clampedIndex + 1)`. Only iOS has a successor, so no other platform is affected.

## 2. Native (iOS only, everything on the main thread)
- `include/just_audio/UriAudioSource.h`: add `@property (nonatomic, strong) NSNumber *replayGainDb;` (nil means unstamped).
- `AudioPlayer.m decodeAudioSource` (:783-790, progressive/dash/hls): after init, set `replayGainDb` when `data[@"replayGainDb"]` is an NSNumber. A clip's child already carries the clip's gain (`just_audio.dart:3595`), so clips need nothing extra.
- `NavisBoost.c/.h`: add `float navis_replaygain_cut_linear(double db)`. It returns `powf(10, min(db,0)/20)`; NaN, ±inf and db >= 0 return 1; the result is clamped to [10^(-60/20), 1]. Use the same function for attach, re-assign and the diagnostics.
- `AudioPlayer.m`: add `- (float)replayGainCutVolumeForItem:(AVPlayerItem *)item`. It resolves `((IndexedPlayerItem *)item).audioSource`, unwraps a `ClippingAudioSource`'s `.audioSource`, and passes `uri.replayGainDb` (nil becomes NaN) to the function above.
- `attachEqualizerToQueue` (:482-489): call `[_equalizer attachToItem:item volume:[self replayGainCutVolumeForItem:item]]`. This is the first assignment, in the same run-loop turn as `insertItem` (enqueueFrom :901-932).
- `NavisEqualizer.h/.m`:
  - Add `float volume` to `NavisEqItemRecord`: the volume that was actually assigned.
  - Add `static AVMutableAudioMix *mixFor(trackID, tap /*NULL ok*/, volume)`, which uses `[p setVolume:v atTime:kCMTimeZero]` as the spike did.
  - `attachToItem:volume:` (:438-467): if the item is already installed, call `setVolume:forItem:`. This covers an item removed and re-inserted on skip-back or reorder, which keeps its old mix today.
  - Add `- (void)setVolume:(float)v forItem:(AVPlayerItem *)item`. It does nothing if there is no record or `record.volume == v`. Otherwise it assigns `item.audioMix = mixFor(record.trackID, tap-or-NULL, v)` (a new object, the same tap, the same trackID) and updates `record.volume`.
- AudioPlayer.m: add `setReplayGainLevels:result:` and wire it into `handleMethodCall` next to :218. It reads `byId` (`SetReplayGainLevelsRequest.toMap`) and `live`.
  - Make one pass over `_indexedAudioSources`: a Uri source, or a clip's child, whose `id` is in `byId` gets a new `replayGainDb`. The heard entry's stored value updates too, so its next start uses it.
  - Then, for each item in `_player.items`, skip `items[0]` unless `live` and call `setVolume:forItem:`.
  - If `_equalizer` is nil, store the values and reply `@{}`.
- Tap failure (`ensureTap` NO, :446-448): assign a mix with no tap, `mixFor(1, NULL, volume)`, always, even at 1.0, so that a later change is a re-assign. Give it the new status `NavisEqItemVolumeOnly`, which means no tap retry for that item. A retry would fire the NSAssert at :450, or stall on a first assignment to a queued item. That stall bug exists today.
- `_equalizer == nil` on iOS (invalid config, :140-141) while Dart has `iosTap` true: accepted, documented regression. Dart builds the config itself, so this case means a Navis bug that already loses the boost and logs `equalizer unavailable`. Handling it would take a second, tap-less mix path through AudioPlayer, which is not worth building for this case. Upgrade path: if it ever shows up, apply the cut in AudioPlayer through `mixFor` at attach.
- EQ pipeline off (`_equalizerPipelineEnabled=false`, no config): Dart is not in-pipeline, nothing is stamped, and the Dart volume cut works as before. Native does nothing.

## 3. Crossfade
iOS crossfades with two AudioPlayers (`_newCrossfadePlayer` → `_buildBaseAudioPlayer`, handler:968-984). Both decks get `equalizerConfiguration` and so each has its own tap and records.
- Each deck's items carry their own cut. `applyVolume` (crossfade:371-375) multiplies `_replayGainVolumeFor`, which now returns base, by the ramp, so the cut is never applied twice.
- The incoming deck gets its stamp when the source is built (crossfade:806/888/915) and a levels+boost send before play (crossfade:831).

## 4. Diagnostics
- `NavisEqualizer state` (around :330-345): add `replayGainCutDb` (the current item's `record.volume` as dB, read from the record and not recomputed) and `replayGainNextCutDb` (the second queued item, through a new `nextItemProvider` block set beside :143). Reading the next value before the boundary is what shows the cut was set at attach and not late.
- `equalizer.dart` (platform interface, :97-222) and `eq_configuration.dart` (:377-415): add those two doubles.
- `media_session.dart:955-962` (iOS branch of `_replayGainBoostStatus`): add `'cutDb'` and `'nextCutDb'` under their own keys. Do not reuse the Android `appliedDb` key, which carries a signed level there.

## 5. Tests first (write them failing)
- `replay_gain_db_test.dart`: `navisReplayGainInPipeline(usesMpv:false, iosTap:true)` is true, and false/false is false.
- `navis_audio_handler_replay_gain_load_test.dart`: keep the existing iOS rows (`pipeline` false) as the no-tap fallback. Add rows with `ios` caps, `pipeline: true` and the boost fake recording both calls. Check each of these:
  - the start song and its iOS successor are stamped, and the successor carries the incoming play order (the §1 fix);
  - `setVolume` equals base, including during the I38 skip while a load is pending;
  - `setReplayGainLevels` and `setReplayGainBoost` are both sent;
  - a failing levels call still sends the boost.
- `navis_audio_handler_navigation_test.dart` (~16420-18090): add an iOS + `equalizerCapabilities` supported variant without the override. Check:
  - a pre-amp or mode change pushes `live`; Off pushes 0;
  - a tag refresh pushes non-live and leaves the volume alone;
  - an insert or queue edit is stamped;
  - toggling repeat or shuffle repushes;
  - the crossfade decks show no double cut;
  - `debugRebuildPlayerWithoutEqualizer` goes back to the volume cut.
  The existing iOS boost assertions must stay unchanged; they are the guard that the boost did not change.
- `test/navis_boost_test.c` (run by `tool/equalizer_native_test.sh`): `navis_replaygain_cut_linear` for NaN, positive, 0, -6.0206 (0.5) and -200 (clamp). The ObjC mix code cannot be covered by a C test, and `ios/RunnerTests` is the app target, so the runtime check covers it. No XCTest is added.
- Edge cases each test or the runtime check must name: first song (stamp at load); skip while a load is pending; a seek inside a song (mix untouched) and to another index (re-attach); radio (null stamp gives 1.0); untagged (the untagged level); Smart with album runs; Off; a pre-amp change mid-song (live re-assign of items[0]); tag refresh; 44.1 to 48 kHz re-prepare (the mix is per item; the tap re-prepares); insert, move and remove; repeat-one and repeat-all (`playerItem2` attaches with the stored cut; the next lap uses an updated value).

## 6. Runtime check (iOS 27.2 sim, then a device), docs, risks
- Runtime: play a tagged queue with mixed gains and read `GET /v1/playback/status`. Expect:
  - `replayGain.cutDb == replayGainBoost.cutDb` on every song;
  - `nextCutDb` already equal to the next song's cut more than 3 s before the boundary;
  - player volume = user volume;
  - the transition gaps (`transitionGapsMs`) stay at 0.0;
  - `tapPrepareCount` and `flushCount` do not change on a pre-amp change.
  Also do a boost/cut pair to confirm the boost fields are unchanged. Frame-exact output at the boundary needs a separate audio capture and is not this check.
- Docs:
  - `docs/architecture.md` ~5269-5340: in-pipeline now includes the iOS cut; rewrite the iOS bullet's "cut stays on AVPlayer.volume"; the Fallback bullet adds iOS without a tap.
  - `docs/plans/iOS_Parity_Plan.md:71`: it is stale ("cut and boost in the shared tap", "blocked until phases 2/3"); restate it as phase A = cut in the mix.
  - `changelog_data.dart` entry with `platforms: {ChangelogPlatform.ios}`; `docs/project/progress.md`.
- Risks:
  - (a) It is unmeasured whether a re-assign on the playing item steps without a ramp; a live change could click. It is a settings-time event only, but it should be listened to.
  - (b) No-stall for re-assigns rests on the sim and macOS spikes; a device run is needed.
  - (c) A trackID other than 1 means the mix does not apply: such a file plays without its cut. Today it plays without EQ or boost (an existing limit, already reported in the state). Count it in the runtime check.
  - (d) The Smart pair change in the boost described in §1.
- Contradictions with the brief: none against the spike facts. Two related findings:
  - a removed-and-re-inserted item keeps its mix, so re-insert needs the re-assign path;
  - the existing tap-retry path already makes a first assignment on a queued item (the stall case), and §2 closes it.
