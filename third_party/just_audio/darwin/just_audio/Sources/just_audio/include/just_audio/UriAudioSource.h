#import "IndexedAudioSource.h"
#import "LoadControl.h"
#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface UriAudioSource : IndexedAudioSource

@property (readonly, nonatomic) NSString *uri;
/// Navis (I26): the signed ReplayGain dB the app stamped on this source; nil means unstamped.
/// The cut half of it is the volume of this source's items' audio mix.
@property (nonatomic, strong) NSNumber *replayGainDb;

- (instancetype)initWithId:(NSString *)sid uri:(NSString *)uri loadControl:(LoadControl *)loadControl headers:(NSDictionary *)headers options:(NSDictionary *)options;

@end
