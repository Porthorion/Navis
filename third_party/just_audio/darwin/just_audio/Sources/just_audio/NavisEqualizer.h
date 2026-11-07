// iOS equalizer: one NavisEqualizer per AudioPlayer. AVFoundation exposes no
// PCM, so each AVPlayerItem near the head of the queue gets an
// MTAudioProcessingTap that runs the shared C DSP (NavisEqualizerDsp.c).
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
/// processedFrames and levelDeltaDb.
- (NSDictionary *)state;
/// Installs the tap once the asset's audio track has loaded. Idempotent.
- (void)attachToItem:(AVPlayerItem *)item;
- (void)dispose;

@end

#endif
