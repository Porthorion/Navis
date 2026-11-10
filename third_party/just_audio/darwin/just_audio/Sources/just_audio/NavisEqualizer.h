// iOS equalizer: one NavisEqualizer per AudioPlayer. AVFoundation exposes no
// PCM, so the player gets one MTAudioProcessingTap, shared by every queued
// AVPlayerItem, that runs the shared C DSP (NavisEqualizerDsp.c). AVQueuePlayer
// starts one audio pipeline per run of items with the same source format, and
// each one prepares that tap, so the tap keeps an EQ stream and a pitch stage
// per audio format (NavisTapFormats.c) and every block runs at its own.
// iOS only (TARGET_OS_IOS): the shared Darwin source also builds for macOS,
// where the whole class compiles away and macOS never receives a config.
#import <AVFoundation/AVFoundation.h>
#include <TargetConditionals.h>

#if TARGET_OS_IOS

@interface NavisEqualizer : NSObject

/// nil with *error set when the configuration map is invalid.
- (instancetype)initWithConfiguration:(NSDictionary *)map error:(NSString **)error;
/// The new state, or nil with *error set. Applies to every live tap.
- (NSDictionary *)setConfiguration:(NSDictionary *)map error:(NSString **)error;
/// Keys: enabled, sampleRate, headroomDb, reason, pending (as on Android) plus
/// processedFrames, levelDeltaDb, resetCount, tapPrepareCount (audio pipelines
/// prepared), flushCount (seeks and skips noted since the tap was created) and
/// transitionGapsMs (the last 8 gaps between songs, in ms; diagnostics). The
/// rate, level and pitch fields describe the format that processed the last
/// block; formatStreams lists every format of the queue, and unmatchedFrames and
/// overlapBlocks count audio no format took (0 when healthy).
- (NSDictionary *)state;
/// Independent pitch in cents (+-2400), applied to the player's one tap; 0 is a
/// bit-exact bypass. Main thread. Safe before the tap exists (it is seeded).
/// The state adds pitchCents, pitchActive, pitchLatencyFrames, pitchResetCount
/// and pitchInputHz/pitchOutputHz (diagnostics), and pitchReason when the tap
/// cannot pitch its audio.
- (void)setPitchCents:(float)cents;
/// ReplayGain boost (I24) in dB for the player's one tap, clamped to 0..12; 0 is a
/// bit-exact bypass. Main thread; the tap ramps every format to it over 20 ms, and
/// snaps at the first block after a flush or a new pipeline (so store a drop before
/// `noteFlush`). `guarded` is only reported. Safe before the tap exists (it is seeded).
/// The state adds boostRequestedDb, boostAppliedDb (the gain the last block ended on),
/// boostGuarded and boostClipSamples (samples beyond full scale after the boost gain).
/// replayGainCutDb and replayGainNextCutDb (I26) are the cut, in dB, last assigned to the current
/// item's audio mix and to the next queued item's; null while that item has none.
- (void)setBoostDb:(double)db guarded:(BOOL)guarded;
/// Gives the item its audio mix (the shared tap, track 1, and `volume`: the ReplayGain cut, I26)
/// synchronously. Idempotent: an item that already has its mix keeps it (see `setVolume:forItem:`).
/// Call it for every item in the same run-loop turn as the insert into the queue, never later:
/// a first mix (or a new tap/track) on a queued item stalls playback; only the volume may move
/// later, through `setVolume:forItem:`. If the tap cannot be created the mix still
/// carries the volume (no tap), and that item is never retried.
- (void)attachToItem:(AVPlayerItem *)item volume:(float)volume;
/// Main thread. Moves the cut of an item that already has its mix: a new mix object (same tap, same
/// track) with `volume`. Nothing happens for an item with no record, or one already at `volume`.
/// The state's replayGainCutDb / replayGainNextCutDb read the volume recorded here.
- (void)setVolume:(float)volume forItem:(AVPlayerItem *)item;
/// The host seeked or skipped: the next block of audio resets the filter history.
- (void)noteFlush;
/// Main thread. The transition gap meter samples only while playing.
- (void)setPlaying:(BOOL)playing;
- (void)dispose;
/// The player's current item (main thread); the state describes that item.
@property (nonatomic, copy) AVPlayerItem *(^currentItemProvider)(void);
/// The item queued after the current one (main thread), for the state's replayGainNextCutDb.
@property (nonatomic, copy) AVPlayerItem *(^nextItemProvider)(void);

@end

#endif
