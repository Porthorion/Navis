// iOS equalizer: one NavisEqualizer per AudioPlayer. AVFoundation exposes no
// PCM, so the player gets one MTAudioProcessingTap, shared by every queued
// AVPlayerItem, that runs the shared C DSP (NavisEqualizerDsp.c).
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
/// processedFrames, levelDeltaDb, resetCount, tapPrepareCount, flushCount (seeks
/// and skips noted since the tap was created) and
/// transitionGapsMs (the last 8 gaps between songs, in ms; diagnostics).
- (NSDictionary *)state;
/// Gives the item its audio mix (the shared tap, track 1) synchronously.
/// Idempotent. Call it for every item in the same run-loop turn as the insert
/// into the queue, never later: changing the mix of a queued item stalls playback.
- (void)attachToItem:(AVPlayerItem *)item;
/// The host seeked or skipped: the next block of audio resets the filter history.
- (void)noteFlush;
/// Main thread. The transition gap meter samples only while playing.
- (void)setPlaying:(BOOL)playing;
- (void)dispose;
/// The player's current item (main thread); the state describes that item.
@property (nonatomic, copy) AVPlayerItem *(^currentItemProvider)(void);

@end

#endif
