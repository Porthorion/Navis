#import "NavisEqualizer.h"

#if TARGET_OS_IOS

#import "NavisEqualizerDsp.h"
#import <MediaToolbox/MediaToolbox.h>
#import <pthread.h>
#import <stdatomic.h>

// MARK: Tap context (plain C: the render path must not touch Objective-C)

typedef struct NavisTapContext {
    pthread_mutex_t lock;
    NavisEqConfig config;  // guarded by lock
    // Set in prepare and cleared in unprepare, both under lock. The SDK header
    // (MTAudioProcessingTap.h) guarantees process runs only between prepare
    // returning and unprepare being called, so process never sees it freed;
    // it is atomic (acquire/release) so that the hand-off is explicit.
    _Atomic(NavisEqStream *) stream;
    // Captured at unprepare so the state stays readable while playback is stopped.
    bool hasSnapshot;                  // guarded by lock
    NavisEqStreamState snapshot;       // guarded by lock
    NavisEqConfig snapshotConfig;      // guarded by lock
    const char *formatReason;          // guarded by lock
    uint64_t retiredFrames;            // frames of streams already freed; guarded by lock
    uint64_t retiredResets;            // history resets of streams already freed; guarded by lock
    atomic_int refs;                   // registry wrapper + tap
} NavisTapContext;

static NavisTapContext *contextNew(const NavisEqConfig *config) {
    NavisTapContext *c = calloc(1, sizeof(NavisTapContext));
    pthread_mutex_init(&c->lock, NULL);
    c->config = *config;
    atomic_init(&c->stream, NULL);
    atomic_init(&c->refs, 1);
    return c;
}

static void contextRetain(NavisTapContext *c) { atomic_fetch_add(&c->refs, 1); }

static void contextRelease(NavisTapContext *c) {
    if (atomic_fetch_sub(&c->refs, 1) != 1) return;
    navis_eq_stream_free(atomic_load(&c->stream));
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
    NavisEqStream *old = atomic_exchange(&c->stream, NULL);
    if (old) { // prepare without unprepare is not expected; do not lose the count
        NavisEqStreamState st;
        navis_eq_stream_state(old, &st);
        c->retiredFrames += st.processedFrames;
        c->retiredResets += st.resetCount;
        navis_eq_stream_free(old);
    }
    c->hasSnapshot = false;
    c->formatReason = NULL;
    BOOL planarFloat = format->mFormatID == kAudioFormatLinearPCM
        && (format->mFormatFlags & kAudioFormatFlagIsFloat)
        && (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        && format->mBitsPerChannel == 32
        && format->mChannelsPerFrame >= 1 && format->mChannelsPerFrame <= NAVIS_EQ_MAX_CHANNELS;
    NavisEqStream *stream = planarFloat
        ? navis_eq_stream_new(&c->config, (int)lround(format->mSampleRate), (int)format->mChannelsPerFrame)
        : NULL;
    if (!stream) c->formatReason = "EQ cannot process this audio format; it plays unchanged.";
    atomic_store_explicit(&c->stream, stream, memory_order_release);
    pthread_mutex_unlock(&c->lock);
}

// The audio machinery stopped calling process (playback stopped or the item
// is done). Free the stream so idle taps do not keep banks, and keep what the
// state needs.
static void tapUnprepare(MTAudioProcessingTapRef tap) {
    NavisTapContext *c = MTAudioProcessingTapGetStorage(tap);
    pthread_mutex_lock(&c->lock);
    NavisEqStream *stream = atomic_exchange(&c->stream, NULL);
    if (stream) {
        navis_eq_stream_state(stream, &c->snapshot);
        // snapshot.pending keeps "requested != applied": an edit that never got
        // swapped in still counts as pending while the tap is stopped.
        c->snapshotConfig = c->config;
        c->hasSnapshot = true;
        c->retiredFrames += c->snapshot.processedFrames;
        c->retiredResets += c->snapshot.resetCount;
        navis_eq_stream_free(stream);
    }
    pthread_mutex_unlock(&c->lock);
}

// Realtime: no locks, allocation, Objective-C or log/pow.
static void tapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                       MTAudioProcessingTapFlags flags, AudioBufferList *bufferList,
                       CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    CMTimeRange sourceRange = kCMTimeRangeInvalid;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut,
                                                         &sourceRange, numberFramesOut);
    if (status != noErr) {
        *numberFramesOut = 0;
        return;
    }
    NavisTapContext *c = MTAudioProcessingTapGetStorage(tap);
    NavisEqStream *stream = atomic_load_explicit(&c->stream, memory_order_acquire);
    if (!stream) return;
    // The source is not continuous with the last block (seek, resumed playback):
    // drop the filter history, like Android's onFlush. The header says the
    // StartOfStream flag marks this, but on iOS 27 it is set only on the first
    // block after prepare, not after a pause or seek; those show up as a jump
    // in the source time range, so check both. The check runs for every block,
    // including ones that cannot be processed below, to keep the expected end
    // of the previous block current.
    BOOL discontinuity = (*flagsOut & kMTAudioProcessingTapFlag_StartOfStream) != 0;
    // While paused or seeking the tap is still called, with an empty source
    // range (zero duration, position stuck); that is not audio, so pass 0 frames.
    if (CMTIMERANGE_IS_VALID(sourceRange) &&
        navis_eq_stream_source_block(stream, CMTimeGetSeconds(sourceRange.start),
                                     CMTimeGetSeconds(sourceRange.duration) > 0 ? (int)*numberFramesOut : 0)) {
        discontinuity = YES;
    }
    UInt32 count = bufferList->mNumberBuffers;
    if (count == 0 || count > NAVIS_EQ_MAX_CHANNELS) return;
    float *channels[NAVIS_EQ_MAX_CHANNELS];
    for (UInt32 i = 0; i < count; i++) {
        if (bufferList->mBuffers[i].mNumberChannels != 1
            || bufferList->mBuffers[i].mDataByteSize < *numberFramesOut * sizeof(float)) return;
        channels[i] = bufferList->mBuffers[i].mData;
    }
    if (discontinuity) navis_eq_stream_reset_history(stream);
    navis_eq_stream_process(stream, channels, (int)count, (int)*numberFramesOut);
}

// MARK: Decoding

static BOOL decodeConfiguration(NSDictionary *raw, NavisEqConfig *out, NSString **error) {
    if (![raw isKindOfClass:[NSDictionary class]]) {
        *error = @"Invalid EQ configuration";
        return NO;
    }
    NSArray *rawFilters = raw[@"filters"];
    if (![rawFilters isKindOfClass:[NSArray class]]
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

typedef NS_ENUM(NSInteger, NavisEqItemStatus) {
    NavisEqItemAttaching = 1, // tracks still loading
    NavisEqItemNoTrack,       // no audio track (HLS before playback, empty track list)
    NavisEqItemLoadFailed,    // the asset failed to load its tracks (or was cancelled)
    NavisEqItemCreateFailed,  // MTAudioProcessingTapCreate failed
    NavisEqItemInstalled,
};

/// Registry entry: keeps the tap context alive while the equalizer lists it.
@interface NavisEqTap : NSObject {
@public
    NavisTapContext *context;
}
@end

@implementation NavisEqTap
- (void)dealloc { contextRelease(context); }
@end

@interface NavisEqItemRecord : NSObject
@property (nonatomic) NavisEqItemStatus status;
@property (nonatomic, strong) NavisEqTap *tap;
@end

@implementation NavisEqItemRecord
@end

@implementation NavisEqualizer {
    NavisEqConfig _config;
    NSMutableArray<NavisEqTap *> *_taps; // taps whose frames are still counted live
    NSMapTable<AVPlayerItem *, NavisEqItemRecord *> *_records;
    uint64_t _retiredFrames;
    BOOL _disposed;
}

- (instancetype)initWithConfiguration:(NSDictionary *)map error:(NSString **)error {
    self = [super init];
    if (!decodeConfiguration(map, &_config, error)) return nil;
    _taps = [[NSMutableArray alloc] init];
    _records = [NSMapTable weakToStrongObjectsMapTable];
    return self;
}

- (NSDictionary *)setConfiguration:(NSDictionary *)map error:(NSString **)error {
    NavisEqConfig next;
    if (!decodeConfiguration(map, &next, error)) return nil;
    if (!_disposed && !navis_eq_config_same(&_config, &next)) {
        _config = next;
        for (NavisEqTap *tap in _taps) {
            NavisTapContext *c = tap->context;
            pthread_mutex_lock(&c->lock);
            c->config = next;
            // Banks are built here, off the audio thread; it swaps at a block
            // boundary. Taps that are not prepared hold no stream and pick the
            // configuration up when they are.
            NavisEqStream *stream = atomic_load(&c->stream);
            if (stream) navis_eq_stream_request(stream, &next);
            pthread_mutex_unlock(&c->lock);
        }
    }
    return [self state];
}

/// Drops taps whose item let go of them (only the registry still references them).
- (void)sweepFinished {
    for (NSInteger i = (NSInteger)_taps.count - 1; i >= 0; i--) {
        NavisEqTap *tap = _taps[i];
        NavisTapContext *c = tap->context;
        if (atomic_load(&c->refs) != 1) continue;
        pthread_mutex_lock(&c->lock);
        _retiredFrames += c->retiredFrames;
        NavisEqStream *stream = atomic_load(&c->stream);
        if (stream) {
            NavisEqStreamState st;
            navis_eq_stream_state(stream, &st);
            _retiredFrames += st.processedFrames;
        }
        pthread_mutex_unlock(&c->lock);
        [_taps removeObjectAtIndex:i];
    }
}

static NSDictionary *stateDictionary(const char *reason, BOOL enabled, id sampleRate, double headroom,
                                     BOOL pending, uint64_t total, id level, id resets) {
    return @{
        @"enabled": @(enabled),
        @"sampleRate": sampleRate ?: (id)[NSNull null],
        @"headroomDb": @(headroom),
        @"reason": reason ? [NSString stringWithUTF8String:reason] : (id)[NSNull null],
        @"pending": @(pending),
        @"processedFrames": @((long long)total),
        @"levelDeltaDb": level ?: (id)[NSNull null],
        @"resetCount": resets ?: (id)[NSNull null],
    };
}

/// The stream state of one tap: live, or captured when it stopped. NO when the
/// tap has not been prepared yet.
static BOOL tapState(NavisTapContext *c, NavisEqStreamState *out, const char **formatReason) {
    BOOL known = NO;
    *formatReason = NULL;
    pthread_mutex_lock(&c->lock);
    NavisEqStream *stream = atomic_load(&c->stream);
    if (stream) {
        navis_eq_stream_state(stream, out);
        navis_eq_stream_sweep(stream);
        out->resetCount += c->retiredResets;
        known = YES;
    } else if (c->hasSnapshot) {
        *out = c->snapshot;
        out->resetCount = c->retiredResets; // includes the snapshot's own
        // An edit made while stopped applies when playback resumes.
        out->pending = out->pending || !navis_eq_config_same(&c->snapshotConfig, &c->config);
        known = YES;
    } else {
        *formatReason = c->formatReason;
    }
    pthread_mutex_unlock(&c->lock);
    return known;
}

- (NSDictionary *)state {
    [self sweepFinished];
    uint64_t total = _retiredFrames;
    for (NavisEqTap *tap in _taps) {
        NavisTapContext *c = tap->context;
        pthread_mutex_lock(&c->lock);
        total += c->retiredFrames;
        NavisEqStream *stream = atomic_load(&c->stream);
        if (stream) {
            NavisEqStreamState st;
            navis_eq_stream_state(stream, &st);
            total += st.processedFrames;
        }
        pthread_mutex_unlock(&c->lock);
    }
    // The current item speaks for the player; a finished song's stream must not
    // hide why the current one is not equalised.
    AVPlayerItem *current = self.currentItemProvider ? self.currentItemProvider() : nil;
    NavisTapContext *context = NULL;
    if (current) {
        NavisEqItemRecord *record = [_records objectForKey:current];
        switch (record ? record.status : NavisEqItemAttaching) {
            case NavisEqItemNoTrack:
                return stateDictionary("This song has no audio track the equalizer can process.", NO, nil, 0, NO, total, nil, nil);
            case NavisEqItemLoadFailed:
                return stateDictionary("The equalizer could not load this song's audio track.", NO, nil, 0, NO, total, nil, nil);
            case NavisEqItemCreateFailed:
                return stateDictionary("The equalizer could not attach to this song.", NO, nil, 0, NO, total, nil, nil);
            case NavisEqItemInstalled:
                context = record.tap->context;
                break;
            default:
                return stateDictionary("The equalizer is attaching to this song.", NO, nil, 0, NO, total, nil, nil);
        }
    } else {
        // No current item (nothing loaded): the latest tap that is running.
        for (NSInteger i = (NSInteger)_taps.count - 1; i >= 0 && !context; i--) {
            if (atomic_load(&_taps[i]->context->stream)) context = _taps[i]->context;
        }
    }
    if (!context) return stateDictionary(NULL, NO, nil, 0, NO, total, nil, nil);
    NavisEqStreamState st = {0};
    const char *formatReason = NULL;
    if (!tapState(context, &st, &formatReason)) {
        // Installed but not prepared: waiting for audio, or an unsupported format.
        return stateDictionary(formatReason ?: "The equalizer is attaching to this song.", NO, nil, 0, NO, total, nil, nil);
    }
    return stateDictionary(st.reason, st.enabled, @(st.sampleRate), st.headroomDb, st.pending, total,
                           st.hasLevel ? @(st.levelDeltaDb) : nil, @((long long)st.resetCount));
}

- (void)attachToItem:(AVPlayerItem *)item {
    if (_disposed || !item) return;
    NavisEqItemRecord *record = [_records objectForKey:item];
    if (record && (record.status == NavisEqItemAttaching || record.status == NavisEqItemInstalled)) return;
    if (!record) {
        record = [[NavisEqItemRecord alloc] init];
        [_records setObject:record forKey:item];
    }
    record.status = NavisEqItemAttaching;
    AVAsset *asset = item.asset;
    if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
        // Already loaded: install now, so no audio plays before the tap exists.
        [self installOnItem:item];
        return;
    }
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
    NavisEqItemRecord *record = [_records objectForKey:item];
    if (_disposed || !record || record.status != NavisEqItemAttaching) return;
    AVAsset *asset = item.asset;
    AVAssetTrack *track = nil;
    AVKeyValueStatus loadStatus = [asset statusOfValueForKey:@"tracks" error:nil];
    if (loadStatus == AVKeyValueStatusLoaded) {
        track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    }
    if (!track) {
        // A failed load, or no audio track (HLS without a track list yet): a
        // later attach retries.
        record.status = loadStatus == AVKeyValueStatusFailed || loadStatus == AVKeyValueStatusCancelled
            ? NavisEqItemLoadFailed : NavisEqItemNoTrack;
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
        record.status = NavisEqItemCreateFailed; // a later attach retries
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
    NavisEqTap *entry = [[NavisEqTap alloc] init];
    entry->context = context; // the entry owns the creation reference
    [_taps addObject:entry];
    record.tap = entry;
    record.status = NavisEqItemInstalled;
    [self sweepFinished];
}

- (void)dispose {
    _disposed = YES;
    for (NavisEqTap *tap in _taps) {
        NavisTapContext *c = tap->context;
        pthread_mutex_lock(&c->lock);
        _retiredFrames += c->retiredFrames;
        pthread_mutex_unlock(&c->lock);
    }
    [_taps removeAllObjects];
}

@end

#endif
