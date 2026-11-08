#import "NavisEqualizer.h"

#if TARGET_OS_IOS

#import "NavisEqualizerDsp.h"
#import "NavisPitchAU.h"
#import "NavisPitchStage.h"
#import "NavisTapFormats.h"
#import <MediaToolbox/MediaToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>

// MARK: Tap context (plain C: the render path must not touch Objective-C)

// AVQueuePlayer runs one audio pipeline per run of items with the same source
// format and prepares/unprepares the one shared tap for each, on non-render
// threads (I25). Everything per format (EQ stream, pitch stage, lock, counters)
// lives in NavisTapFormats.c; this file is the MediaToolbox glue around it.
typedef struct NavisTapContext {
    NavisTapFormats *formats;
    // Bumped by the host (main thread) for a seek or skip; the render thread
    // hands it to the format set, which resets the filter history of the slot
    // that sees it (see navis_eq_stream_begin_block).
    _Atomic uint32_t flushGeneration;
    atomic_int refs;                   // owner (the equalizer) + the tap
} NavisTapContext;

// The AU behind a slot's pitch stage: created in tapPrepare, freed with the slot.
static void *pitchAuCreate(double rate, int channels, int maxFrames, NavisPitchRenderer *out) {
    NavisPitchAU *au = navis_pitch_au_new(rate, channels, maxFrames);
    if (au) *out = navis_pitch_au_renderer(au);
    return au;
}

static void pitchAuDestroy(void *au) { navis_pitch_au_free(au); }

static uint64_t pitchAuMismatches(const void *au) { return navis_pitch_au_pull_mismatches(au); }

static NavisTapContext *contextNew(const NavisEqConfig *config, int32_t pitchCents) {
    NavisTapContext *c = calloc(1, sizeof(NavisTapContext));
    NavisPitchFactory factory = {pitchAuCreate, pitchAuDestroy, pitchAuMismatches};
    c->formats = navis_tap_formats_new(config, pitchCents, factory);
    atomic_init(&c->flushGeneration, 0);
    atomic_init(&c->refs, 1);
    return c;
}

static void contextRetain(NavisTapContext *c) { atomic_fetch_add(&c->refs, 1); }

static void contextRelease(NavisTapContext *c) {
    if (atomic_fetch_sub(&c->refs, 1) != 1) return;
    navis_tap_formats_free(c->formats);
    free(c);
}

static void tapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    contextRetain(clientInfo);
    *tapStorageOut = clientInfo;
}

static void tapFinalize(MTAudioProcessingTapRef tap) {
    contextRelease(MTAudioProcessingTapGetStorage(tap));
}

// Not realtime: allocation and locking are fine here. One call per pipeline.
static void tapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                       const AudioStreamBasicDescription *format) {
    NavisTapContext *c = MTAudioProcessingTapGetStorage(tap);
    BOOL planarFloat = format->mFormatID == kAudioFormatLinearPCM
        && (format->mFormatFlags & kAudioFormatFlagIsFloat)
        && (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        && format->mBitsPerChannel == 32
        && format->mChannelsPerFrame >= 1 && format->mChannelsPerFrame <= NAVIS_EQ_MAX_CHANNELS;
    // A format that cannot get a slot sets its reason in the state; its blocks pass unchanged.
    navis_tap_formats_prepare(c->formats, format->mSampleRate, (int)format->mChannelsPerFrame,
                              (int)maxFrames, planarFloat);
}

// A pipeline ended (its last item is done). Frees nothing: the format slots are
// kept for the next song, a seek or a resume.
static void tapUnprepare(MTAudioProcessingTapRef tap) {
    NavisTapContext *c = MTAudioProcessingTapGetStorage(tap);
    if (!navis_tap_formats_unprepare(c->formats)) {
        NSLog(@"just_audio: equalizer tap unprepared without a matching prepare");
    }
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
    // A layout the tap cannot process plays unchanged; tell the state, so it does
    // not show the previous format as processing (an atomic store, no lock).
    UInt32 count = bufferList->mNumberBuffers;
    if (count == 0 || count > NAVIS_EQ_MAX_CHANNELS) {
        navis_tap_formats_note_dry(c->formats, (int)*numberFramesOut);
        return;
    }
    float *channels[NAVIS_EQ_MAX_CHANNELS];
    for (UInt32 i = 0; i < count; i++) {
        if (bufferList->mBuffers[i].mNumberChannels != 1
            || bufferList->mBuffers[i].mDataByteSize < *numberFramesOut * sizeof(float)) {
            navis_tap_formats_note_dry(c->formats, (int)*numberFramesOut);
            return;
        }
        channels[i] = bufferList->mBuffers[i].mData;
    }
    // The duration of the source range is the block's own clock: frames over it is
    // the block's rate, which picks the format slot (the probe always saw the
    // timescale equal to the source rate). While paused, seeking or right after
    // prepare the range is empty or invalid: that is not audio, and the
    // StartOfStream flag can arrive on the block after it. The filter history is
    // dropped on StartOfStream and when the host flushed (seek, skip), never on
    // the range's start, which re-bases without any jump in the audio whenever an
    // item is inserted behind the playing one.
    int64_t value = 0;
    int32_t timescale = 0;
    if (CMTIMERANGE_IS_VALID(sourceRange) && CMTIME_IS_NUMERIC(sourceRange.duration)
        && sourceRange.duration.value > 0 && sourceRange.duration.timescale > 0) {
        value = sourceRange.duration.value;
        timescale = sourceRange.duration.timescale;
    }
    navis_tap_formats_process(c->formats, (*flagsOut & kMTAudioProcessingTapFlag_StartOfStream) != 0,
                              atomic_load_explicit(&c->flushGeneration, memory_order_relaxed),
                              value, timescale, channels, (int)count, (int)*numberFramesOut);
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
@property (nonatomic) BOOL reportedOtherTrack; // logged once that the audio track is not the one mixed
@property (nonatomic) CMPersistentTrackID trackID; // the audio track the mix names
@end

@implementation NavisEqItemRecord
@end

// One tap per player. AVQueuePlayer runs an item that has its own tap through
// its own audio pipeline and starts the next item's only after the previous one
// drained (0.4 to 1.2 s of silence at every transition); items sharing one tap
// share one pipeline and join sample-continuously. Every item gets its mix
// before it plays, in the same run-loop turn as its insert, without loading
// tracks (track 1 unless already loaded): changing the mix of an item AVQueuePlayer already
// prerolls rebuilds the pipeline and stalls playback for about 0.5 s.
@implementation NavisEqualizer {
    NavisEqConfig _config;
    int32_t _pitchCents;            // requested pitch; seeds the tap, which is created on first use
    NavisTapContext *_context;      // created with the tap; this object holds one reference
    MTAudioProcessingTapRef _tap;
    NSMapTable<AVPlayerItem *, NavisEqItemRecord *> *_records;
    BOOL _disposed;
    // Transition gap meter (main thread).
    NSTimer *_meterTimer;
    BOOL _meterEnabled;             // diagnostics builds only
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

// The first AudioUnit created in a process loads its component, which took 2.6 s
// on a Mac and would delay the first song of the session if it happened in the
// first tapPrepare. Create and free one unit, once, on a utility queue when the
// first equalizer is made. It is never attached to a tap: tap AUs are created in
// tapPrepare (one per audio format) and freed with the tap, nowhere else.
static void warmUpPitchAudioUnit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            navis_pitch_au_free(navis_pitch_au_new(44100, 2, 4096));
        });
    });
}

- (instancetype)initWithConfiguration:(NSDictionary *)map error:(NSString **)error {
    self = [super init];
    if (!decodeConfiguration(map, &_config, error)) return nil;
    warmUpPitchAudioUnit();
    // The app sets this only where the diagnostics API may run (diagnosticsBuildEnabled).
    _meterEnabled = [map[@"diagnostics"] isKindOfClass:[NSNumber class]] && [map[@"diagnostics"] boolValue];
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
        // Banks are built here, off the audio thread; every format's stream swaps at
        // a block boundary. A format prepared later is seeded with the configuration.
        if (_context) navis_tap_formats_configure(_context->formats, &next);
    }
    return [self state];
}

- (void)setPitchCents:(float)cents {
    if (_disposed) return;
    int32_t clamped = (int32_t)lroundf(fmaxf(-NAVIS_PITCH_MAX_CENTS, fminf(NAVIS_PITCH_MAX_CENTS, cents)));
    _pitchCents = clamped;
    // Every format's stage picks the change up at its next block; a format
    // prepared later is seeded with it.
    if (_context) navis_tap_formats_set_cents(_context->formats, clamped);
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
    NavisTapFormatsState fs;
    memset(&fs, 0, sizeof fs);
    long long flushes = 0;
    BOOL live = _context && !_disposed;
    if (live) {
        navis_tap_formats_state(_context->formats, &fs);
        flushes = (long long)atomic_load(&_context->flushGeneration);
    }
    NSMutableDictionary *result = [[self baseStateFrom:live ? &fs : NULL] mutableCopy];
    [self addPitchStateTo:result from:live ? &fs : NULL];
    result[@"tapPrepareCount"] = @((long long)fs.prepareCalls);
    // The balance of the pipelines the tap saw; starting over at the cap is safe only
    // while these match (clampedUnprepares and, when idle, livePipelines stay 0).
    result[@"livePipelines"] = @(fs.livePipelines);
    result[@"prepareCalls"] = @((long long)fs.prepareCalls);
    result[@"unprepareCalls"] = @((long long)fs.unprepareCalls);
    result[@"clampedUnprepares"] = @((long long)fs.clampedUnprepares);
    result[@"flushCount"] = @(flushes);
    result[@"transitionGapsMs"] = [_gapsMs copy];
    // One entry per audio format of the queue (slots outlive their pipelines), and
    // the audio no format took; both stay 0 / complete in a healthy run.
    NSMutableArray *formats = [[NSMutableArray alloc] init];
    for (int i = 0; i < fs.slotCount; i++) {
        const NavisTapFormatInfo *f = &fs.formats[i];
        [formats addObject:@{
            @"sampleRate": @(f->sampleRate),
            @"channels": @(f->channels),
            @"processedFrames": @((long long)f->processedFrames),
            @"levelDeltaDb": f->hasLevel ? @(f->levelDeltaDb) : (id)[NSNull null],
        }];
    }
    result[@"formatStreams"] = formats;
    result[@"unmatchedFrames"] = @((long long)fs.unmatchedFrames);
    result[@"overlapBlocks"] = @((long long)fs.overlapBlocks);
    return result;
}

/// pitchCents is the request; the rest is the slot that processed the last block.
- (void)addPitchStateTo:(NSMutableDictionary *)result from:(const NavisTapFormatsState *)fs {
    NavisPitchState st = {0};
    if (fs && fs->hasPitch) st = fs->pitch;
    st.cents = _pitchCents;
    result[@"pitchCents"] = @(st.cents);
    result[@"pitchActive"] = @(st.active);
    result[@"pitchLatencyFrames"] = @(st.latencyFrames);
    result[@"pitchResetCount"] = @((long long)(fs ? fs->pitchResetCount : 0));
    result[@"pitchInputHz"] = @(st.inputHz);
    result[@"pitchOutputHz"] = @(st.outputHz);
    result[@"pitchPullMismatches"] = @((long long)(fs ? fs->pitchPullMismatches : 0));
    if (fs && fs->pitchReason) result[@"pitchReason"] = [NSString stringWithUTF8String:fs->pitchReason];
}

- (NSDictionary *)baseStateFrom:(const NavisTapFormatsState *)fs {
    uint64_t total = fs ? fs->processedFrames : 0;
    if (!fs) return stateDictionary(nil, NO, nil, 0, NO, total, nil, nil);
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
        if (trackID > 0 && trackID != record.trackID) {
            if (!record.reportedOtherTrack) {
                record.reportedOtherTrack = YES;
                NSLog(@"just_audio: equalizer cannot process this item: its audio track ID is %ld, the mix names %d", (long)trackID, (int)record.trackID);
            }
            return stateDictionary([NSString stringWithFormat:@"This song's audio track has ID %ld but the equalizer mixed track %d, so it plays unchanged.", (long)trackID, (int)record.trackID],
                                   NO, nil, 0, NO, total, nil, nil);
        }
    }
    // No format yet (waiting for audio), or the song being played has none (an
    // unsupported format, or too many formats in this queue).
    if (!fs->hasStream || fs->formatReason) {
        return stateDictionary(reasonString(fs->formatReason) ?: @"The equalizer is attaching to this song.", NO, nil, 0, NO, total, nil, nil);
    }
    const NavisEqStreamState *st = &fs->stream;
    return stateDictionary(reasonString(st->reason), st->enabled, @(st->sampleRate), st->headroomDb, st->pending, total,
                           st->hasLevel ? @(st->levelDeltaDb) : nil, @((long long)fs->resetCount));
}

/// Creates the player's one tap on first use. NO when MTAudioProcessingTapCreate fails.
- (BOOL)ensureTap {
    if (_context) return YES;
    NavisTapContext *context = contextNew(&_config, _pitchCents);
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
    // Track 1 unless the asset's tracks are already loaded (a non-blocking check):
    // loading them here would hit the network and reach the next item late.
    CMPersistentTrackID trackID = 1;
    AVAsset *asset = item.asset;
    if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
        AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        if (audio) trackID = audio.trackID;
    }
    record.trackID = trackID;
    parameters.trackID = trackID;
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
    if (playing && _meterEnabled && !_meterTimer && !_disposed) {
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
    // item.duration only: the asset's own getter can block the main thread. A stream
    // reports it late; the tick is skipped until it is finite.
    double duration = CMTimeGetSeconds(item.duration);
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
