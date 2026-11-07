#import "NavisEqualizer.h"

#if TARGET_OS_IOS

#import "NavisEqualizerDsp.h"
#import <MediaToolbox/MediaToolbox.h>
#import <pthread.h>
#import <stdatomic.h>

// MARK: Tap context (plain C: the render path must not touch Objective-C)

typedef struct NavisTapContext {
    pthread_mutex_t lock;
    NavisEqConfig config;     // guarded by lock
    NavisEqStream *stream;    // replaced under lock in prepare; used by process lock-free
    const char *formatReason; // guarded by lock
    uint64_t retiredFrames;   // frames of streams replaced by a re-prepare; guarded by lock
    atomic_int refs;          // registry + tap
    // Main thread only.
    uint64_t lastSeenFrames, activeTick;
} NavisTapContext;

static NavisTapContext *contextNew(const NavisEqConfig *config) {
    NavisTapContext *c = calloc(1, sizeof(NavisTapContext));
    pthread_mutex_init(&c->lock, NULL);
    c->config = *config;
    atomic_init(&c->refs, 1);
    return c;
}

static void contextRetain(NavisTapContext *c) { atomic_fetch_add(&c->refs, 1); }

static void contextRelease(NavisTapContext *c) {
    if (atomic_fetch_sub(&c->refs, 1) != 1) return;
    navis_eq_stream_free(c->stream);
    pthread_mutex_destroy(&c->lock);
    free(c);
}

static void tapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    contextRetain(clientInfo);
    *tapStorageOut = clientInfo;
}

static void tapFinalize(MTAudioProcessingTapRef tap) {
    contextRelease(MTAudioProcessingTapGetStorage(tap));
}

// Not realtime: allocation and locking are fine here.
static void tapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                       const AudioStreamBasicDescription *format) {
    NavisTapContext *c = MTAudioProcessingTapGetStorage(tap);
    pthread_mutex_lock(&c->lock);
    if (c->stream) {
        NavisEqStreamState old;
        navis_eq_stream_state(c->stream, &old);
        c->retiredFrames += old.processedFrames;
        navis_eq_stream_free(c->stream);
        c->stream = NULL;
    }
    c->formatReason = NULL;
    BOOL planarFloat = format->mFormatID == kAudioFormatLinearPCM
        && (format->mFormatFlags & kAudioFormatFlagIsFloat)
        && (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        && format->mBitsPerChannel == 32
        && format->mChannelsPerFrame >= 1 && format->mChannelsPerFrame <= NAVIS_EQ_MAX_CHANNELS;
    if (planarFloat) {
        c->stream = navis_eq_stream_new(&c->config, (int)lround(format->mSampleRate),
                                        (int)format->mChannelsPerFrame);
    }
    if (!c->stream) {
        c->formatReason = "EQ cannot process this audio format; it plays unchanged.";
    }
    pthread_mutex_unlock(&c->lock);
}

static void tapUnprepare(MTAudioProcessingTapRef tap) {}

// Realtime: no locks, allocation, Objective-C or log/pow.
static void tapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                       MTAudioProcessingTapFlags flags, AudioBufferList *bufferList,
                       CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut,
                                                         NULL, numberFramesOut);
    if (status != noErr) {
        *numberFramesOut = 0;
        return;
    }
    NavisTapContext *c = MTAudioProcessingTapGetStorage(tap);
    NavisEqStream *stream = c->stream;
    UInt32 count = bufferList->mNumberBuffers;
    if (!stream || count == 0 || count > NAVIS_EQ_MAX_CHANNELS) return;
    float *channels[NAVIS_EQ_MAX_CHANNELS];
    for (UInt32 i = 0; i < count; i++) {
        if (bufferList->mBuffers[i].mNumberChannels != 1
            || bufferList->mBuffers[i].mDataByteSize < *numberFramesOut * sizeof(float)) return;
        channels[i] = bufferList->mBuffers[i].mData;
    }
    navis_eq_stream_process(stream, channels, (int)count, (int)*numberFramesOut);
}

// MARK: Decoding

static BOOL decodeConfiguration(NSDictionary *raw, NavisEqConfig *out, NSString **error) {
    NSArray *rawFilters = raw[@"filters"];
    if (![raw isKindOfClass:[NSDictionary class]] || ![rawFilters isKindOfClass:[NSArray class]]
        || rawFilters.count > NAVIS_EQ_MAX_FILTERS
        || ![raw[@"enabled"] isKindOfClass:[NSNumber class]]
        || ![raw[@"autoHeadroom"] isKindOfClass:[NSNumber class]]
        || ![raw[@"preampDb"] isKindOfClass:[NSNumber class]]) {
        *error = @"Invalid EQ configuration";
        return NO;
    }
    memset(out, 0, sizeof(*out));
    out->enabled = [raw[@"enabled"] boolValue];
    out->autoHeadroom = [raw[@"autoHeadroom"] boolValue];
    out->preamp = [raw[@"preampDb"] doubleValue];
    out->filterCount = (int)rawFilters.count;
    for (NSUInteger i = 0; i < rawFilters.count; i++) {
        NSDictionary *f = rawFilters[i];
        if (![f isKindOfClass:[NSDictionary class]]
            || ![f[@"type"] isKindOfClass:[NSString class]]
            || ![f[@"frequencyHz"] isKindOfClass:[NSNumber class]]
            || ![f[@"gainDb"] isKindOfClass:[NSNumber class]]
            || ![f[@"q"] isKindOfClass:[NSNumber class]]
            || ![f[@"enabled"] isKindOfClass:[NSNumber class]]) {
            *error = @"Invalid EQ filter";
            return NO;
        }
        out->filters[i] = (NavisEqFilter){
            .type = navis_eq_filter_type_from_name([f[@"type"] UTF8String]),
            .frequency = [f[@"frequencyHz"] doubleValue],
            .gain = [f[@"gainDb"] doubleValue],
            .q = [f[@"q"] doubleValue],
            .enabled = [f[@"enabled"] boolValue],
        };
    }
    if (!navis_eq_config_valid(out)) {
        *error = @"EQ configuration is outside supported limits";
        return NO;
    }
    return YES;
}

// MARK: NavisEqualizer

@implementation NavisEqualizer {
    NavisEqConfig _config;
    NSMutableArray<NSValue *> *_contexts; // retained NavisTapContext pointers
    NSMapTable<AVPlayerItem *, NSNumber *> *_attached;
    uint64_t _retiredFrames, _tick;
    BOOL _disposed;
}

- (instancetype)initWithConfiguration:(NSDictionary *)map error:(NSString **)error {
    self = [super init];
    if (!decodeConfiguration(map, &_config, error)) return nil;
    _contexts = [[NSMutableArray alloc] init];
    _attached = [NSMapTable weakToStrongObjectsMapTable];
    return self;
}

- (NSDictionary *)setConfiguration:(NSDictionary *)map error:(NSString **)error {
    NavisEqConfig next;
    if (!decodeConfiguration(map, &next, error)) return nil;
    if (!_disposed && !navis_eq_config_same(&_config, &next)) {
        _config = next;
        for (NSValue *value in _contexts) {
            NavisTapContext *c = value.pointerValue;
            pthread_mutex_lock(&c->lock);
            c->config = next;
            // Banks are built here, off the audio thread; it swaps at a block boundary.
            if (c->stream) navis_eq_stream_request(c->stream, &next);
            pthread_mutex_unlock(&c->lock);
        }
    }
    return [self state];
}

/// Drops contexts whose tap is gone (only the registry still references them).
- (void)sweepFinished {
    for (NSInteger i = (NSInteger)_contexts.count - 1; i >= 0; i--) {
        NavisTapContext *c = _contexts[i].pointerValue;
        if (atomic_load(&c->refs) != 1) continue;
        NavisEqStreamState st = {0};
        pthread_mutex_lock(&c->lock);
        _retiredFrames += c->retiredFrames;
        if (c->stream) {
            navis_eq_stream_state(c->stream, &st);
            _retiredFrames += st.processedFrames;
        }
        pthread_mutex_unlock(&c->lock);
        [_contexts removeObjectAtIndex:i];
        contextRelease(c);
    }
}

- (NSDictionary *)state {
    [self sweepFinished];
    uint64_t total = _retiredFrames;
    NavisTapContext *selected = NULL;
    NavisEqStreamState selectedState = {0};
    const char *reason = NULL;
    for (NSValue *value in _contexts) {
        NavisTapContext *c = value.pointerValue;
        pthread_mutex_lock(&c->lock);
        total += c->retiredFrames;
        if (c->stream) {
            NavisEqStreamState st;
            navis_eq_stream_state(c->stream, &st);
            navis_eq_stream_sweep(c->stream);
            total += st.processedFrames;
            // The stream that processed audio most recently speaks for the player.
            if (st.processedFrames > c->lastSeenFrames) c->activeTick = ++_tick;
            c->lastSeenFrames = st.processedFrames;
            if (!selected || c->activeTick >= selected->activeTick) {
                selected = c;
                selectedState = st;
            }
        } else if (c->formatReason) {
            reason = c->formatReason;
        }
        pthread_mutex_unlock(&c->lock);
    }
    if (selected) reason = selectedState.reason;
    return @{
        @"enabled": @((BOOL)(selected && selectedState.enabled)),
        @"sampleRate": selected ? @(selectedState.sampleRate) : (id)[NSNull null],
        @"headroomDb": @(selected ? selectedState.headroomDb : 0.0),
        @"reason": reason ? [NSString stringWithUTF8String:reason] : (id)[NSNull null],
        @"pending": @((BOOL)(selected && selectedState.pending)),
        @"processedFrames": @((long long)total),
        // Only the level of audio that actually played is meaningful.
        @"levelDeltaDb": selected && selectedState.hasLevel ? @(selectedState.levelDeltaDb) : (id)[NSNull null],
    };
}

- (void)attachToItem:(AVPlayerItem *)item {
    if (_disposed || !item || [_attached objectForKey:item]) return;
    [_attached setObject:@YES forKey:item];
    AVAsset *asset = item.asset;
    __weak __typeof__(self) weakSelf = self;
    __weak AVPlayerItem *weakItem = item;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *strongItem = weakItem;
            if (strongItem) [weakSelf installOnItem:strongItem];
        });
    }];
}

- (void)installOnItem:(AVPlayerItem *)item {
    AVAsset *asset = item.asset;
    if (_disposed) return;
    AVAssetTrack *track = nil;
    if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
        track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    }
    if (!track) {
        // Not ready (or HLS without a track list yet): let a later attach retry.
        [_attached removeObjectForKey:item];
        return;
    }
    NavisTapContext *context = contextNew(&_config);
    MTAudioProcessingTapCallbacks callbacks = {
        .version = kMTAudioProcessingTapCallbacksVersion_0,
        .clientInfo = context,
        .init = tapInit,
        .finalize = tapFinalize,
        .prepare = tapPrepare,
        .unprepare = tapUnprepare,
        .process = tapProcess,
    };
    MTAudioProcessingTapRef tap = NULL;
    // Before the player's own effects (speed, volume): the DSP sees the source rate.
    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                 kMTAudioProcessingTapCreationFlag_PreEffects, &tap);
    if (status != noErr || !tap) {
        contextRelease(context);
        return;
    }
    AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    parameters.audioTapProcessor = tap;
    CFRelease(tap);
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[parameters];
    // Installed once and kept (bypassing inside the DSP): changing the mix of a
    // playing item can drop out.
    item.audioMix = mix;
    [_contexts addObject:[NSValue valueWithPointer:context]];
    [self sweepFinished];
}

- (void)dispose {
    _disposed = YES;
    for (NSValue *value in _contexts) {
        NavisTapContext *c = value.pointerValue;
        pthread_mutex_lock(&c->lock);
        _retiredFrames += c->retiredFrames;
        pthread_mutex_unlock(&c->lock);
        contextRelease(c);
    }
    [_contexts removeAllObjects];
}

- (void)dealloc {
    [self dispose];
}

@end

#endif
