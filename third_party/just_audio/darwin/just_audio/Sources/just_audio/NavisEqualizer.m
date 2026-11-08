#import "NavisEqualizer.h"

#if TARGET_OS_IOS

#import "NavisEqualizerDsp.h"
#import <MediaToolbox/MediaToolbox.h>
#import <QuartzCore/QuartzCore.h>
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
    uint64_t prepareCount;             // times the tap was prepared; guarded by lock
    // Bumped by the host (main thread) for a seek or skip; the render thread
    // resets the filter history when it sees a new value (see begin_block).
    _Atomic uint32_t flushGeneration;
    atomic_int refs;                   // owner (the equalizer) + the tap
} NavisTapContext;

static NavisTapContext *contextNew(const NavisEqConfig *config) {
    NavisTapContext *c = calloc(1, sizeof(NavisTapContext));
    pthread_mutex_init(&c->lock, NULL);
    c->config = *config;
    atomic_init(&c->stream, NULL);
    atomic_init(&c->flushGeneration, 0);
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
    c->prepareCount++;
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
    // The filter history is dropped on StartOfStream (the first block after
    // prepare) and when the host flushed (seek, skip); never on the source time
    // range, which re-bases without any jump in the audio whenever an item is
    // inserted behind the playing one. While paused, seeking or right after
    // prepare the tap is still called with an empty or invalid source range;
    // that is not audio (StartOfStream can arrive on the block after it). The
    // decision runs before the layout checks below so a block that cannot be
    // processed still consumes the event.
    int audioFrames = CMTIMERANGE_IS_VALID(sourceRange) && CMTimeGetSeconds(sourceRange.duration) > 0
        ? (int)*numberFramesOut : 0;
    navis_eq_stream_begin_block(stream, (*flagsOut & kMTAudioProcessingTapFlag_StartOfStream) != 0,
                                atomic_load_explicit(&c->flushGeneration, memory_order_relaxed), audioFrames);
    UInt32 count = bufferList->mNumberBuffers;
    if (count == 0 || count > NAVIS_EQ_MAX_CHANNELS) return;
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
    NavisEqItemCreateFailed = 1, // MTAudioProcessingTapCreate failed
    NavisEqItemInstalled,
};

@interface NavisEqItemRecord : NSObject
@property (nonatomic) NavisEqItemStatus status;
@property (nonatomic) BOOL reportedOtherTrack; // logged once that the audio track is not track 1
@end

@implementation NavisEqItemRecord
@end

// One tap per player. AVQueuePlayer runs an item that has its own tap through
// its own audio pipeline and starts the next item's only after the previous one
// drained (0.4 to 1.2 s of silence at every transition); items sharing one tap
// share one pipeline and join sample-continuously. Every item gets its mix
// before it plays, in the same run-loop turn as its insert, without loading
// tracks (trackID 1): changing the mix of an item AVQueuePlayer already
// prerolls rebuilds the pipeline and stalls playback for about 0.5 s.
@implementation NavisEqualizer {
    NavisEqConfig _config;
    NavisTapContext *_context;      // created with the tap; this object holds one reference
    MTAudioProcessingTapRef _tap;
    NSMapTable<AVPlayerItem *, NavisEqItemRecord *> *_records;
    BOOL _disposed;
    // Transition gap meter (main thread).
    NSTimer *_meterTimer;
    NSMutableArray<NSNumber *> *_gapsMs;
    __weak AVPlayerItem *_meterItem;
    double _meterDuration;
    NSMutableArray<NSNumber *> *_startOffsets;  // wall minus item time, the item's first samples
    NSMutableArray<NSNumber *> *_lastOffsets;   // the same for its latest samples before the end
    BOOL _gapReported;                          // this item's start was compared with the previous end
    double _carryOffset;            // previous item's median end offset, NAN when unknown
    double _carryDuration;
}

static const NSUInteger kGapHistory = 8;
static const NSTimeInterval kMeterInterval = 0.02;
static const NSUInteger kMeterSamples = 5; // medians over this many samples absorb clock jitter

- (instancetype)initWithConfiguration:(NSDictionary *)map error:(NSString **)error {
    self = [super init];
    if (!decodeConfiguration(map, &_config, error)) return nil;
    _records = [NSMapTable weakToStrongObjectsMapTable];
    _gapsMs = [[NSMutableArray alloc] init];
    [self resetMeter];
    return self;
}

- (NSDictionary *)setConfiguration:(NSDictionary *)map error:(NSString **)error {
    NavisEqConfig next;
    if (!decodeConfiguration(map, &next, error)) return nil;
    if (!_disposed && !navis_eq_config_same(&_config, &next)) {
        _config = next;
        NavisTapContext *c = _context;
        if (c) {
            pthread_mutex_lock(&c->lock);
            c->config = next;
            // Banks are built here, off the audio thread; it swaps at a block
            // boundary. A tap that is not prepared holds no stream and picks the
            // configuration up when it is.
            NavisEqStream *stream = atomic_load(&c->stream);
            if (stream) navis_eq_stream_request(stream, &next);
            pthread_mutex_unlock(&c->lock);
        }
    }
    return [self state];
}

static NSDictionary *stateDictionary(NSString *reason, BOOL enabled, id sampleRate, double headroom,
                                     BOOL pending, uint64_t total, id level, id resets) {
    return @{
        @"enabled": @(enabled),
        @"sampleRate": sampleRate ?: (id)[NSNull null],
        @"headroomDb": @(headroom),
        @"reason": reason ?: (id)[NSNull null],
        @"pending": @(pending),
        @"processedFrames": @((long long)total),
        @"levelDeltaDb": level ?: (id)[NSNull null],
        @"resetCount": resets ?: (id)[NSNull null],
    };
}

static NSString *reasonString(const char *reason) {
    return reason ? [NSString stringWithUTF8String:reason] : nil;
}

/// The stream state of the tap: live, or captured when it stopped. NO when the
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

/// Track ID of the item's first audio track once the item is ready to play, else 0.
/// Reads only what the item already loaded; never starts a load.
static NSInteger firstAudioTrackID(AVPlayerItem *item) {
    if (item.status != AVPlayerItemStatusReadyToPlay) return 0;
    for (AVPlayerItemTrack *track in item.tracks) {
        AVAssetTrack *asset = track.assetTrack;
        if (asset && [asset.mediaType isEqualToString:AVMediaTypeAudio]) return asset.trackID;
    }
    return 0;
}

- (NSDictionary *)state {
    NSMutableDictionary *result = [[self baseState] mutableCopy];
    long long prepares = 0, flushes = 0;
    if (_context && !_disposed) {
        pthread_mutex_lock(&_context->lock);
        prepares = (long long)_context->prepareCount;
        pthread_mutex_unlock(&_context->lock);
        flushes = (long long)atomic_load(&_context->flushGeneration);
    }
    result[@"tapPrepareCount"] = @(prepares);
    result[@"flushCount"] = @(flushes);
    result[@"transitionGapsMs"] = [_gapsMs copy];
    return result;
}

- (NSDictionary *)baseState {
    NavisTapContext *context = _disposed ? NULL : _context;
    uint64_t total = 0;
    if (context) {
        pthread_mutex_lock(&context->lock);
        total = context->retiredFrames;
        NavisEqStream *stream = atomic_load(&context->stream);
        if (stream) {
            NavisEqStreamState st;
            navis_eq_stream_state(stream, &st);
            total += st.processedFrames;
        }
        pthread_mutex_unlock(&context->lock);
    }
    if (!context) return stateDictionary(nil, NO, nil, 0, NO, total, nil, nil);
    // The current item speaks for the player; a finished song's stream must not
    // hide why the current one is not equalised.
    AVPlayerItem *current = self.currentItemProvider ? self.currentItemProvider() : nil;
    if (current) {
        NavisEqItemRecord *record = [_records objectForKey:current];
        if (!record) return stateDictionary(@"The equalizer is attaching to this song.", NO, nil, 0, NO, total, nil, nil);
        if (record.status == NavisEqItemCreateFailed) {
            return stateDictionary(@"The equalizer could not attach to this song.", NO, nil, 0, NO, total, nil, nil);
        }
        // The mix names track 1 so no track has to be loaded; a file whose audio
        // track has another ID plays unchanged. It is never re-mixed (that stalls
        // playback), so only say so.
        NSInteger trackID = firstAudioTrackID(current);
        if (trackID > 1 || trackID < 0) {
            if (!record.reportedOtherTrack) {
                record.reportedOtherTrack = YES;
                NSLog(@"just_audio: equalizer cannot process this item: its audio track ID is %ld, not 1", (long)trackID);
            }
            return stateDictionary([NSString stringWithFormat:@"This song's audio track has ID %ld; the equalizer only processes track 1, so it plays unchanged.", (long)trackID],
                                   NO, nil, 0, NO, total, nil, nil);
        }
    }
    NavisEqStreamState st = {0};
    const char *formatReason = NULL;
    if (!tapState(context, &st, &formatReason)) {
        // Installed but not prepared: waiting for audio, or an unsupported format.
        return stateDictionary(reasonString(formatReason) ?: @"The equalizer is attaching to this song.", NO, nil, 0, NO, total, nil, nil);
    }
    return stateDictionary(reasonString(st.reason), st.enabled, @(st.sampleRate), st.headroomDb, st.pending, total,
                           st.hasLevel ? @(st.levelDeltaDb) : nil, @((long long)st.resetCount));
}

/// Creates the player's one tap on first use. NO when MTAudioProcessingTapCreate fails.
- (BOOL)ensureTap {
    if (_context) return YES;
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
        return NO; // a later attach retries
    }
    _context = context; // this object owns the creation reference
    _tap = tap;         // and the creation reference of the tap
    return YES;
}

- (void)attachToItem:(AVPlayerItem *)item {
    if (_disposed || !item) return;
    NavisEqItemRecord *record = [_records objectForKey:item];
    if (record && record.status == NavisEqItemInstalled) return;
    if (!record) {
        record = [[NavisEqItemRecord alloc] init];
        [_records setObject:record forKey:item];
    }
    if (![self ensureTap]) {
        record.status = NavisEqItemCreateFailed;
        return;
    }
    NSAssert(item.audioMix == nil, @"an item's audio mix must be set once, before it is queued");
    AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParameters];
    parameters.trackID = 1;
    parameters.audioTapProcessor = _tap;
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[parameters];
    // Installed once and kept (bypassing inside the DSP when the EQ is off).
    item.audioMix = mix;
    record.status = NavisEqItemInstalled;
}

- (void)noteFlush {
    if (_context && !_disposed) atomic_fetch_add(&_context->flushGeneration, 1);
    [self resetMeter];
}

// MARK: Transition gap meter
//
// Diagnostics: the silence between two songs on the player's own clock, the
// same arithmetic as the offline analysis of the I23 investigation. Per item,
// `offset = wall time - item time`; the gap from item n to n+1 is
// `startOffset(n+1) - endOffset(n) - duration(n)` (medians of five samples): 0 when sample-continuous,
// positive for silence. A 50 Hz main-thread timer runs only while playing; a
// seek, skip or load clears the sampler and the gaps.

- (void)resetMeter {
    [_gapsMs removeAllObjects]; // gaps are those since the last seek, skip or load
    _meterItem = nil;
    _meterDuration = 0;
    _startOffsets = [[NSMutableArray alloc] init];
    _lastOffsets = [[NSMutableArray alloc] init];
    _gapReported = YES;
    _carryOffset = _carryDuration = NAN;
}

static double medianOf(NSArray<NSNumber *> *values) {
    if (values.count == 0) return NAN;
    NSArray<NSNumber *> *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    return sorted[sorted.count / 2].doubleValue;
}

- (void)setPlaying:(BOOL)playing {
    if (playing && !_meterTimer && !_disposed) {
        __weak __typeof__(self) weakSelf = self;
        _meterTimer = [NSTimer scheduledTimerWithTimeInterval:kMeterInterval repeats:YES block:^(NSTimer *timer) {
            [weakSelf sampleMeter];
        }];
    } else if (!playing && _meterTimer) {
        [_meterTimer invalidate];
        _meterTimer = nil;
    }
}

- (void)sampleMeter {
    AVPlayerItem *item = self.currentItemProvider ? self.currentItemProvider() : nil;
    if (!item) return;
    double time = CMTimeGetSeconds(item.currentTime);
    double duration = CMTimeGetSeconds(item.duration);
    if (!isfinite(duration) || duration <= 0) duration = CMTimeGetSeconds(item.asset.duration); // streams report it late
    if (!isfinite(time) || !isfinite(duration) || duration <= 0) return;
    double offset = CACurrentMediaTime() - time;
    if (item != _meterItem) {
        _carryOffset = medianOf(_lastOffsets);
        _carryDuration = _meterDuration;
        _meterItem = item;
        _meterDuration = duration;
        [_startOffsets removeAllObjects];
        [_lastOffsets removeAllObjects];
        _gapReported = isnan(_carryOffset);
    }
    if (time <= 0.05) return;
    if (_startOffsets.count < kMeterSamples) [_startOffsets addObject:@(offset)];
    if (time < duration - 0.03) {
        [_lastOffsets addObject:@(offset)];
        if (_lastOffsets.count > kMeterSamples) [_lastOffsets removeObjectAtIndex:0];
    }
    if (!_gapReported && _startOffsets.count == kMeterSamples) {
        _gapReported = YES;
        double gap = medianOf(_startOffsets) - _carryOffset - _carryDuration;
        [_gapsMs addObject:@(round(gap * 10000) / 10)]; // ms, 0.1 ms steps
        if (_gapsMs.count > kGapHistory) [_gapsMs removeObjectAtIndex:0];
    }
}

- (void)dealloc {
    [self dispose];
}

- (void)dispose {
    _disposed = YES;
    [self setPlaying:NO];
    if (_context) {
        if (_tap) CFRelease(_tap);
        _tap = NULL;
        NavisTapContext *context = _context;
        _context = NULL;
        contextRelease(context);
    }
}

@end

#endif
