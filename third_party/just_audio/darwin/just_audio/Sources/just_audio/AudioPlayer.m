#import "./include/just_audio/BetterEventChannel.h"
#import "./include/just_audio/AudioPlayer.h"
#import "./include/just_audio/AudioSource.h"
#import "./include/just_audio/IndexedAudioSource.h"
#import "./include/just_audio/LoadControl.h"
#import "./include/just_audio/UriAudioSource.h"
#import "./include/just_audio/ConcatenatingAudioSource.h"
#import "./include/just_audio/LoopingAudioSource.h"
#import "./include/just_audio/ClippingAudioSource.h"
#import "NavisBoost.h"
#import "NavisEqualizer.h"
#import "NavisRatePlan.h"
#import <AVFoundation/AVFoundation.h>
#import <stdlib.h>
#include <TargetConditionals.h>

#define TREADMILL_SIZE 2
#if TARGET_OS_IOS
// A ReplayGain boost rise waits this long after the last song event (the desktop
// replayGainBoostRaiseAfter). The throwaway hold-gate build of the I24 proof sets it to 0.
static const int64_t kBoostRaiseAfterMs = 500;
// The tick that moves the boost into and out of the guard window, on the main queue.
static const int kBoostTickMs = 250;
#endif
#define ERROR_ABORT 10000000
// I45 (#526): the item clock may start after the Playing stamp. The 200 ms observer
// re-stamps the position once it has drifted from the stamp by more than this.
static const long long kRestampDriftMs = 50;

// TODO: Check for and report invalid state transitions.
// TODO: Apply Apple's guidance on seeking: https://developer.apple.com/library/archive/qa/qa1820/_index.html
@implementation AudioPlayer {
    NSObject<FlutterPluginRegistrar>* _registrar;
    FlutterMethodChannel *_methodChannel;
    BetterEventChannel *_eventChannel;
    BetterEventChannel *_dataEventChannel;
    NSString *_playerId;
    AVQueuePlayer *_player;
    AudioSource *_audioSource;
    NSMutableArray<IndexedAudioSource *> *_indexedAudioSources;
    NSArray<NSNumber *> *_order;
    NSMutableArray<NSNumber *> *_orderInv;
    int _index;
    enum ProcessingState _processingState;
    enum LoopMode _loopMode;
    BOOL _shuffleModeEnabled;
    long long _updateTime;
    int _updatePosition;
    int _lastPosition;
    int _bufferedPosition;
    // Set when the current item hasn't been played yet so we aren't sure whether sufficient audio has been buffered.
    BOOL _bufferUnconfirmed;
    CMTime _seekPos;
    FlutterResult _loadResult;
    FlutterResult _playResult;
    id _timeObserver;
    BOOL _automaticallyWaitsToMinimizeStalling;
    BOOL _allowsExternalPlayback;
    LoadControl *_loadControl;
    BOOL _useLazyPreparation;
    BOOL _playing;
    float _speed;
    float _volume;
    BOOL _justAdvanced;
    BOOL _enqueuedAll;
    NSDictionary<NSString *, NSObject *> *_icyMetadata;
    NSNumber *_errorCode;
    NSString *_errorMessage;
    BOOL _commandFlushed;             // Navis: a seek, skip or load flushed and is about to call enqueueFrom:
#if TARGET_OS_IOS
    // Navis: nil unless the app sent an equalizerConfiguration (iOS only).
    NavisEqualizer *_equalizer;
    // Navis: Pitch Lock (#528). The last pitch factor (_speed is the speed), the algorithm every item
    // plays with, and whether one applyRatePlan is already queued (main thread).
    double _pitch;
    AVAudioTimePitchAlgorithm _timePitchAlgorithm;
    BOOL _ratePlanPending;
    // Navis: the ReplayGain boost (I24), all on the main thread. The map is the boost of each
    // queued song by URI; the rest is the policy state of navis_boost_decide.
    NSDictionary<NSString *, NSNumber *> *_boostByUri;
    NSDictionary<NSString *, NSNumber *> *_boostTagDurationMsByUri; // the song tags' durations, sent with the map
    BOOL _boostMapPositive;           // some song has a boost: only then the tick runs
    double _boostTargetDb;            // the target in force, dB
    BOOL _boostReportedGuarded;
    BOOL _boostLatched;               // the playing song stays guarded until the next song event
    BOOL _boostHeld;                  // a rise waits (a song event < kBoostRaiseAfterMs ago)
    uint64_t _boostEvents;            // bumped by every song event: cancels the pending rise
    __weak AVPlayerItem *_boostItem;  // the item the last song event was for
    id _boostObserver;                // the tick
#endif
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar playerId:(NSString*)idParam loadConfiguration:(NSDictionary *)loadConfiguration useLazyPreparation:(BOOL)useLazyPreparation equalizerConfiguration:(NSDictionary *)equalizerConfiguration {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _registrar = registrar;
    _playerId = idParam;
    _useLazyPreparation = useLazyPreparation;
    _methodChannel =
        [FlutterMethodChannel methodChannelWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.methods.%@", _playerId]
                                    binaryMessenger:[registrar messenger]];
    _eventChannel = [[BetterEventChannel alloc]
        initWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.events.%@", _playerId]
           messenger:[registrar messenger]];
    _dataEventChannel = [[BetterEventChannel alloc]
        initWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.data.%@", _playerId]
           messenger:[registrar messenger]];
    _index = 0;
    _processingState = psIdle;
    _loopMode = lmLoopOff;
    _shuffleModeEnabled = NO;
    _player = nil;
    _audioSource = nil;
    _indexedAudioSources = nil;
    _order = nil;
    _orderInv = nil;
    _seekPos = kCMTimeInvalid;
    _timeObserver = 0;
    _updatePosition = 0;
    _updateTime = 0;
    _lastPosition = 0;
    _bufferedPosition = 0;
    _bufferUnconfirmed = NO;
    _playing = NO;
    _loadResult = nil;
    _playResult = nil;
    _automaticallyWaitsToMinimizeStalling = YES;
    _allowsExternalPlayback = NO;
    _loadControl = nil;
    if (loadConfiguration != (id)[NSNull null]) {
        NSDictionary *map = loadConfiguration[@"darwinLoadControl"];
        if (map != (id)[NSNull null]) {
            _loadControl = [[LoadControl alloc] init];
            _loadControl.preferredForwardBufferDuration = (NSNumber *)map[@"preferredForwardBufferDuration"];
            _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused = (BOOL)[map[@"canUseNetworkResourcesForLiveStreamingWhilePaused"] boolValue];
            _loadControl.preferredPeakBitRate = (NSNumber *)map[@"preferredPeakBitRate"];
            _automaticallyWaitsToMinimizeStalling = (BOOL)[map[@"automaticallyWaitsToMinimizeStalling"] boolValue];
        }
    }
    if (!_loadControl) {
        _loadControl = [[LoadControl alloc] init];
        _loadControl.preferredForwardBufferDuration = (NSNumber *)[NSNull null];
        _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused = NO;
        _loadControl.preferredPeakBitRate = (NSNumber *)[NSNull null];
    }
#if TARGET_OS_IOS
    if (equalizerConfiguration) {
        NSString *equalizerError = nil;
        _equalizer = [[NavisEqualizer alloc] initWithConfiguration:equalizerConfiguration error:&equalizerError];
        if (!_equalizer) NSLog(@"just_audio: equalizer unavailable: %@", equalizerError);
        __weak __typeof__(self) weakSelf = self;
        _equalizer.currentItemProvider = ^AVPlayerItem *{ return weakSelf.player.currentItem; };
        _equalizer.nextItemProvider = ^AVPlayerItem *{
            NSArray<AVPlayerItem *> *items = weakSelf.player.items;
            return items.count > 1 ? items[1] : nil;
        };
    }
    _pitch = 1.0;
    _timePitchAlgorithm = AVAudioTimePitchAlgorithmTimeDomain;
#endif
    _speed = 1.0f;
    _volume = 1.0f;
    _justAdvanced = NO;
    _enqueuedAll = NO;
    _icyMetadata = @{};
    _errorCode = (NSNumber *)[NSNull null];
    _errorMessage = (NSString *)[NSNull null];
    __weak __typeof__(self) weakSelf = self;
    [_methodChannel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
        [weakSelf handleMethodCall:call result:result];
    }];
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    @try {
        //NSLog(@"method: %@ index=%d", call.method, _index);
        NSDictionary *request = (NSDictionary *)call.arguments;
        if ([@"load" isEqualToString:call.method]) {
            CMTime initialPosition = request[@"initialPosition"] == (id)[NSNull null] ? kCMTimeInvalid : CMTimeMake([request[@"initialPosition"] longLongValue], 1000000);
            [self load:request[@"audioSource"] initialPosition:initialPosition initialIndex:request[@"initialIndex"] result:result];
        } else if ([@"play" isEqualToString:call.method]) {
            [self play:result];
        } else if ([@"pause" isEqualToString:call.method]) {
            [self pause];
            result(@{});
        } else if ([@"setVolume" isEqualToString:call.method]) {
            [self setVolume:(float)[request[@"volume"] doubleValue]];
            result(@{});
        } else if ([@"setSkipSilence" isEqualToString:call.method]) {
            /// TODO on iOS side; Seems more involved, so someone with ObjectiveC experience might look at it.
            result(@{});
        } else if ([@"setSpeed" isEqualToString:call.method]) {
            [self setSpeed:(float)[request[@"speed"] doubleValue]];
            result(@{});
        } else if ([@"setPitch" isEqualToString:call.method]) {
            [self setPitch:[request[@"pitch"] doubleValue] result:result];
        } else if ([@"setLoopMode" isEqualToString:call.method]) {
            [self setLoopMode:[request[@"loopMode"] intValue]];
            result(@{});
        } else if ([@"setShuffleMode" isEqualToString:call.method]) {
            [self setShuffleModeEnabled:(BOOL)([request[@"shuffleMode"] intValue] == 1)];
            result(@{});
        } else if ([@"setShuffleOrder" isEqualToString:call.method]) {
            [self setShuffleOrder:(NSDictionary *)request[@"audioSource"]];
            result(@{});
        } else if ([@"setAutomaticallyWaitsToMinimizeStalling" isEqualToString:call.method]) {
            [self setAutomaticallyWaitsToMinimizeStalling:(BOOL)[request[@"enabled"] boolValue]];
            result(@{});
        } else if ([@"setCanUseNetworkResourcesForLiveStreamingWhilePaused" isEqualToString:call.method]) {
            [self setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)[request[@"enabled"] boolValue]];
            result(@{});
        } else if ([@"setPreferredPeakBitRate" isEqualToString:call.method]) {
            [self setPreferredPeakBitRate:(NSNumber *)request[@"bitRate"]];
            result(@{});
        } else if ([@"setAllowsExternalPlayback" isEqualToString:call.method]) {
            [self setAllowsExternalPlayback:(BOOL)([request[@"allowsExternalPlayback"] intValue] == 1)];
            result(@{});
        } else if ([@"seek" isEqualToString:call.method]) {
            CMTime position = request[@"position"] == (id)[NSNull null] ? kCMTimePositiveInfinity : CMTimeMake([request[@"position"] longLongValue], 1000000);
            [self seek:position index:request[@"index"] completionHandler:^(BOOL finished) {
                result(@{});
            }];
        } else if ([@"concatenatingInsertAll" isEqualToString:call.method]) {
            [self concatenatingInsertAll:(NSString *)request[@"id"] index:[request[@"index"] intValue] sources:(NSArray *)request[@"children"] shuffleOrder:(NSArray<NSNumber *> *)request[@"shuffleOrder"]];
            result(@{});
        } else if ([@"concatenatingRemoveRange" isEqualToString:call.method]) {
            [self concatenatingRemoveRange:(NSString *)request[@"id"] start:[request[@"startIndex"] intValue] end:[request[@"endIndex"] intValue] shuffleOrder:(NSArray<NSNumber *> *)request[@"shuffleOrder"]];
            result(@{});
        } else if ([@"concatenatingMove" isEqualToString:call.method]) {
            [self concatenatingMove:(NSString *)request[@"id"] currentIndex:[request[@"currentIndex"] intValue] newIndex:[request[@"newIndex"] intValue] shuffleOrder:(NSArray<NSNumber *> *)request[@"shuffleOrder"]];
            result(@{});
        } else if ([@"setReplayGainBoost" isEqualToString:call.method]) {
            [self setReplayGainBoost:request result:result];
        } else if ([@"setReplayGainLevels" isEqualToString:call.method]) {
            [self setReplayGainLevels:request result:result];
        } else if ([@"setEqualizer" isEqualToString:call.method]) {
            [self setEqualizer:request result:result];
        } else if ([@"getEqualizerState" isEqualToString:call.method]) {
            [self getEqualizerState:result];
        } else if ([@"setAndroidAudioAttributes" isEqualToString:call.method]) {
            result(@{});
        } else {
            result(FlutterMethodNotImplemented);
        }
    } @catch (NSException *exception) {
        //NSLog(@"%@", [exception callStackSymbols]);
        FlutterError *flutterError = [FlutterError errorWithCode:@"error" message:@"Error in handleMethodCall" details:nil];
        result(flutterError);
    }
}

// Navis: pitch (iOS). Independent pitch is 1200*log2(factor) cents in an AUNewTimePitch inside
// the equalizer's tap, with items on the time-domain algorithm. Pitch Lock (pitch == speed) is
// instead one Varispeed resample in AVPlayer with the tap at 0 (see applyRatePlan). Without a tap
// only 1 and a locked pair succeed.
- (void)setPitch:(double)pitch result:(FlutterResult)result {
    if (!isfinite(pitch) || pitch < 0.25 || pitch > 4) {
        result([FlutterError errorWithCode:@"pitch_invalid" message:@"Pitch factor must be between 0.25 and 4" details:nil]);
        return;
    }
#if TARGET_OS_IOS
    if (_equalizer || pitch == 1.0 || navis_rate_plan(_speed, pitch).algorithm == NAVIS_RATE_VARISPEED) {
        _pitch = pitch;
        [self scheduleRatePlan];
        result(@{});
        return;
    }
#else
    if (pitch == 1.0) {
        result(@{});
        return;
    }
#endif
    result([FlutterError errorWithCode:@"pitch_unavailable" message:@"No audio tap was installed for this player" details:nil]);
}

#if TARGET_OS_IOS
// Navis: Pitch Lock (#528). Dart sends setSpeed and setPitch back to back, so both are queued
// before this runs and the plan is made once from the final pair: no algorithm flap in between.
// ponytail: coalesces only messages already queued; a combined setSpeedPitch method if a flap is ever heard.
- (void)scheduleRatePlan {
    if (_ratePlanPending) return;
    _ratePlanPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self applyRatePlan]; });
}

// Locked (and not 1x): every item plays through AVPlayer's own Varispeed resample, the tap's pitch is
// 0 and its EQ bands move to f/speed. Otherwise: time-domain stretch and the tap's independent pitch.
// The algorithm goes on every item that exists: playing, queued and not yet inserted (and the loop item).
- (void)applyRatePlan {
    _ratePlanPending = NO;
    NavisRatePlan plan = navis_rate_plan(_speed, _pitch);
    [_equalizer setPitchCents:plan.tapCents];
    [_equalizer setFrequencyScale:plan.eqFrequencyScale];
    AVAudioTimePitchAlgorithm algorithm = plan.algorithm == NAVIS_RATE_VARISPEED
        ? AVAudioTimePitchAlgorithmVarispeed : AVAudioTimePitchAlgorithmTimeDomain;
    if ([algorithm isEqualToString:_timePitchAlgorithm]) return;
    _timePitchAlgorithm = algorithm;
    for (AVPlayerItem *item in _player.items) item.audioTimePitchAlgorithm = algorithm;
    for (IndexedAudioSource *source in _indexedAudioSources) {
        source.playerItem.audioTimePitchAlgorithm = algorithm;
        source.playerItem2.audioTimePitchAlgorithm = algorithm;
    }
    // AVPlayer may pick up an item's algorithm only on the next rate set (device check owed).
    // Not mid-seek: the seek paused the player and its completion sets the rate itself.
    if (_playing && _player && CMTIME_IS_INVALID(_seekPos)) _player.rate = _speed;
}
#endif

/// Queue insert (always at the end). A new item gets the current Pitch Lock algorithm first.
- (void)insertQueueItem:(AVPlayerItem *)item {
#if TARGET_OS_IOS
    item.audioTimePitchAlgorithm = _timePitchAlgorithm;
#endif
    [_player insertItem:item afterItem:nil];
}

// Navis: equalizer (iOS). Unsupported where no tap was installed, as on Android.
- (void)setEqualizer:(NSDictionary *)request result:(FlutterResult)result {
#if TARGET_OS_IOS
    if (_equalizer) {
        NSString *error = nil;
        NSDictionary *state = [_equalizer setConfiguration:request error:&error];
        result(state ?: [FlutterError errorWithCode:@"eq_invalid" message:error details:nil]);
        return;
    }
#endif
    result([FlutterError errorWithCode:@"eq_unavailable" message:@"No EQ processor was installed for this player" details:nil]);
}

- (void)getEqualizerState:(FlutterResult)result {
#if TARGET_OS_IOS
    if (_equalizer) {
        NSMutableDictionary *state = [[_equalizer state] mutableCopy];
        state[@"timePitchAlgorithm"] = [_timePitchAlgorithm isEqualToString:AVAudioTimePitchAlgorithmVarispeed] ? @"varispeed" : @"timeDomain";
        result(state);
        return;
    }
#endif
    result([FlutterError errorWithCode:@"eq_unavailable" message:@"No EQ processor was installed for this player" details:nil]);
}

// MARK: Navis: ReplayGain boost (iOS, I24)
//
// AVPlayer.volume stops at 1.0, so a boost is a gain stage in the equalizer's tap, after
// pitch and EQ. Dart sends the boost of every queued song by URI (the per-file map the
// desktop player gets). This side owns the timing: it knows the real next item and changes
// the queue in the same run-loop turn, so a song's samples never get more than its own boost
// (navis_boost_decide): inside the last 3 s the target is the lower of the two songs', a
// drop applies at once and a rise waits kBoostRaiseAfterMs after the last song event.

- (void)setReplayGainBoost:(NSDictionary *)request result:(FlutterResult)result {
#if TARGET_OS_IOS
    if (!_equalizer) {
        result([FlutterError errorWithCode:@"boost_unavailable" message:@"No audio tap was installed for this player" details:nil]);
        return;
    }
    NSDictionary *raw = [request[@"byUri"] isKindOfClass:[NSDictionary class]] ? request[@"byUri"] : @{};
    NSMutableDictionary<NSString *, NSNumber *> *map = [NSMutableDictionary dictionaryWithCapacity:raw.count];
    BOOL positive = NO;
    for (id key in raw) {
        id value = raw[key];
        if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSNumber class]]) continue;
        double db = [value doubleValue];
        db = db > 0 ? fmin(db, NAVIS_BOOST_MAX_DB) : 0;
        map[key] = @(db);
        positive = positive || db > 0;
    }
    NSDictionary *rawDurations = [request[@"durationMsByUri"] isKindOfClass:[NSDictionary class]] ? request[@"durationMsByUri"] : @{};
    NSMutableDictionary<NSString *, NSNumber *> *durations = [NSMutableDictionary dictionaryWithCapacity:rawDurations.count];
    for (id key in rawDurations) {
        id value = rawDurations[key];
        if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSNumber class]] && [value doubleValue] > 0) durations[key] = value;
    }
    _boostByUri = map;
    _boostTagDurationMsByUri = durations;
    _boostMapPositive = positive;
    [self updateBoostObserver];
    [self refreshReplayGainBoost];
    result(@{});
#else
    result(FlutterMethodNotImplemented);
#endif
}

#if TARGET_OS_IOS
/// The map key of a queue entry: its URI, or its child's for a clip.
- (NSString *)boostUriOfSource:(IndexedAudioSource *)source {
    if ([source isKindOfClass:[ClippingAudioSource class]]) return ((ClippingAudioSource *)source).audioSource.uri;
    if ([source isKindOfClass:[UriAudioSource class]]) return ((UriAudioSource *)source).uri;
    return nil;
}

/// The boost the map gives queue entry `index`: 0 for an unknown entry or URI.
- (double)boostOwnDbAtIndex:(int)index {
    if (index < 0 || index >= (int)_indexedAudioSources.count) return 0;
    NSString *uri = [self boostUriOfSource:_indexedAudioSources[index]];
    double db = uri ? _boostByUri[uri].doubleValue : 0;
    return db > 0 ? fmin(db, NAVIS_BOOST_MAX_DB) : 0;
}

/// The queue index after `index` in play order (the destination of a jump, which is
/// not queued yet), or -1.
- (int)boostIndexAfter:(int)index {
    if (index < 0 || index >= (int)_orderInv.count) return -1;
    if (_loopMode == lmLoopOne) return index;
    NSUInteger position = (NSUInteger)[_orderInv[index] intValue];
    if (position + 1 < _order.count) return [_order[position + 1] intValue];
    return _loopMode == lmLoopAll && _order.count > 0 ? [_order[0] intValue] : -1;
}

/// The position of `source` for the guard in media ms, or NAN. A pending seek's target is the
/// position; otherwise the source's own clock, which reads its `playerItem` and so is only right
/// while that is the item being heard (not before a loop-all wrap has flipped it).
- (double)boostPositionMsOfSource:(IndexedAudioSource *)source {
    if (CMTIME_IS_VALID(_seekPos)) {
        double seconds = CMTimeGetSeconds(_seekPos);
        return isfinite(seconds) ? seconds * 1000 : NAN;
    }
    NSArray<AVPlayerItem *> *heard = _player.items;
    if (heard.count == 0 || heard[0] != source.playerItem) return NAN;
    return CMTimeGetSeconds(source.position) * 1000;
}

/// Runs the decision for song `index` followed by `nextIndex` (-1: none) and hands the target to the
/// tap when it changed. `positionMs` is the position in the song (NAN: read the source's clock).
/// `latch` stores the guard's latch; a jump (a seek, a queue edit) has no settled clock and never latches.
- (void)applyBoostForIndex:(int)index next:(int)nextIndex position:(double)positionMs latch:(BOOL)latch {
    NavisBoostInput in = {
        .ownDb = [self boostOwnDbAtIndex:index],
        .nextDb = nextIndex >= 0 ? [self boostOwnDbAtIndex:nextIndex] : NAN,
        .positionMs = NAN, .playerDurationMs = NAN, .tagDurationMs = NAN, .speed = _speed,
        .latched = _boostLatched, .held = _boostHeld, .previousDb = _boostTargetDb,
    };
    if (index >= 0 && index < (int)_indexedAudioSources.count) {
        IndexedAudioSource *source = _indexedAudioSources[index];
        in.playerDurationMs = CMTimeGetSeconds(source.duration) * 1000;
        NSString *uri = [self boostUriOfSource:source];
        in.tagDurationMs = uri ? _boostTagDurationMsByUri[uri].doubleValue : NAN;
        in.positionMs = isnan(positionMs) ? [self boostPositionMsOfSource:source] : positionMs;
    }
    NavisBoostOutput out;
    navis_boost_decide(&in, NAVIS_BOOST_GUARD_WINDOW_MS, &out);
    if (latch) _boostLatched = out.latched;
    if (out.targetDb != _boostTargetDb || out.guarded != _boostReportedGuarded) {
        _boostTargetDb = out.targetDb;
        _boostReportedGuarded = out.guarded;
        [_equalizer setBoostDb:out.targetDb guarded:out.guarded];
    }
}

/// A song event: the song's guard resets and a rise waits. The hold ends on its own timer
/// unless a newer event replaced it.
- (void)noteBoostSongEvent {
    _boostLatched = NO;
    _boostHeld = YES;
    uint64_t generation = ++_boostEvents;
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kBoostRaiseAfterMs * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_boostEvents != generation) return;
        strongSelf->_boostHeld = NO;
        [strongSelf refreshReplayGainBoost];
    });
}

- (void)updateBoostObserver {
    BOOL want = _equalizer && _player && _boostMapPositive;
    if (want && !_boostObserver) {
        __weak __typeof__(self) weakSelf = self;
        _boostObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(kBoostTickMs, 1000)
                                                               queue:dispatch_get_main_queue()
                                                          usingBlock:^(CMTime time) {
            [weakSelf refreshReplayGainBoost];
        }];
    } else if (!want && _boostObserver) {
        [_player removeTimeObserver:_boostObserver];
        _boostObserver = nil;
    }
}
#endif

/// Recomputes the target for what the player plays now and what is queued behind it.
- (void)refreshReplayGainBoost {
#if TARGET_OS_IOS
    if (!_equalizer || !_player) return;
    NSArray<AVPlayerItem *> *items = _player.items;
    int index = items.count > 0 ? [self indexForItem:(IndexedPlayerItem *)items[0]] : -1;
    int next = items.count > 1 ? [self indexForItem:(IndexedPlayerItem *)items[1]] : -1;
    [self applyBoostForIndex:index next:next position:NAN latch:YES];
#endif
}

/// The current item or the queue behind it changed (the `currentItem` observer and the end of
/// enqueueFrom:). A new current item is a song event.
- (void)noteBoostQueueChanged {
#if TARGET_OS_IOS
    if (!_equalizer || !_player) return;
    if (_player.currentItem != _boostItem) {
        _boostItem = _player.currentItem;
        [self noteBoostSongEvent];
    }
    [self refreshReplayGainBoost];
#endif
}

/// A new queue is loading: its songs are not in the map yet, so the boost drops to 0 (held),
/// before the flush so that the first block after it plays at 0.
- (void)noteBoostLoad {
#if TARGET_OS_IOS
    if (!_equalizer) return;
    _boostItem = nil;
    [self noteBoostSongEvent];
    [self applyBoostForIndex:-1 next:-1 position:NAN latch:NO];
#endif
}

/// The playing song is about to change by a jump: a seek or skip, or a queue edit that removed the
/// playing item (before the flush, so the first block after it plays at the destination's value). The
/// destination is judged on its own and the song after it in play order, at `positionMs` (NAN:
/// unknown, which guards without latching). A position and a known duration (the tag's, if the
/// player has none yet) let a seek inside the playing song keep its own boost; the hold still keeps
/// a rise back, and the decision never latches.
- (void)noteBoostJumpToIndex:(int)destination positionMs:(double)positionMs {
#if TARGET_OS_IOS
    if (!_equalizer || !_player) return;
    [self noteBoostSongEvent];
    [self applyBoostForIndex:destination next:[self boostIndexAfter:destination] position:positionMs latch:NO];
#endif
}

- (void)noteBoostSeekToIndex:(NSNumber *)newIndex position:(CMTime)position {
#if TARGET_OS_IOS
    int destination = (newIndex != nil && newIndex != (id)[NSNull null]) ? [newIndex intValue] : _index;
    double seconds = CMTIME_IS_NUMERIC(position) ? CMTimeGetSeconds(position) : NAN;
    [self noteBoostJumpToIndex:destination positionMs:isfinite(seconds) ? seconds * 1000 : NAN];
#endif
}

// Every queued item gets the equalizer's shared tap and its ReplayGain cut in the same run-loop turn
// as its insert (see enqueueFrom:). Attaching is synchronous and loads no tracks, so covering the
// whole queue costs nothing. An item that already has its mix keeps it, except that the cut is
// re-assigned if it moved (an item removed and re-inserted by a skip back or a reorder); `heard`,
// the item that keeps playing through this rebuild, is never touched: its cut is frozen at its
// start and only a live setReplayGainLevels moves it.
- (void)attachEqualizerToQueueKeeping:(AVPlayerItem *)heard {
#if TARGET_OS_IOS
    for (AVPlayerItem *item in _player.items) {
        float volume = [self replayGainCutVolumeForItem:item];
        [_equalizer attachToItem:item volume:volume];
        if (item != heard) [_equalizer setVolume:volume forItem:item];
    }
#endif
}

#if TARGET_OS_IOS
/// The uri source whose stamp governs `item`: the item's own, or a clip's child.
static UriAudioSource *uriSourceOf(IndexedAudioSource *source) {
    if ([source isKindOfClass:[ClippingAudioSource class]]) return ((ClippingAudioSource *)source).audioSource;
    if ([source isKindOfClass:[UriAudioSource class]]) return (UriAudioSource *)source;
    return nil;
}

/// The volume of the item's ReplayGain cut (I26), from the dB stamped on its source: 1 for an
/// unstamped item (radio, nil).
- (float)replayGainCutVolumeForItem:(AVPlayerItem *)item {
    UriAudioSource *source = uriSourceOf(((IndexedPlayerItem *)item).audioSource);
    return navis_replaygain_cut_linear(source.replayGainDb ? source.replayGainDb.doubleValue : NAN);
}
#endif

// MARK: Navis: ReplayGain cut in the item audio mix (iOS, I26)
//
// Each item's audio mix carries its own ReplayGain cut as the input volume, so the cut starts at
// the item's first sample. The app stamps the signed dB on each source (`replayGainDb`, in the load
// and insert messages) and sends later changes here by source id. Everything is on the main thread.
// The heard item (items[0]) changes only for a `live` push, as the Dart handler freezes it at its start.

- (void)setReplayGainLevels:(NSDictionary *)request result:(FlutterResult)result {
#if TARGET_OS_IOS
    NSDictionary *byId = [request[@"byId"] isKindOfClass:[NSDictionary class]] ? request[@"byId"] : @{};
    BOOL live = [request[@"live"] respondsToSelector:@selector(boolValue)] && [request[@"live"] boolValue];
    // One pass over the queue entries: a clip is keyed by its child, which holds the stamp.
    // The heard entry's stored value updates too, so its next start uses it.
    for (IndexedAudioSource *indexed in _indexedAudioSources) {
        UriAudioSource *source = uriSourceOf(indexed);
        id value = source.sourceId ? byId[source.sourceId] : nil;
        if ([value isKindOfClass:[NSNumber class]]) source.replayGainDb = value;
    }
    if (_equalizer) {
        NSArray<AVPlayerItem *> *items = _player.items;
        for (NSUInteger i = 0; i < items.count; i++) {
            if (i == 0 && !live) continue;
            [_equalizer setVolume:[self replayGainCutVolumeForItem:items[i]] forItem:items[i]];
        }
    }
#endif
    result(@{});
}

// Navis: a seek, skip or new load; the equalizer drops its filter history at
// the next block of audio.
- (void)noteEqualizerFlush {
#if TARGET_OS_IOS
    [_equalizer noteFlush];
#endif
}

// Navis: the transition gap meter samples only while playing.
- (void)noteEqualizerPlaying:(BOOL)playing {
#if TARGET_OS_IOS
    [_equalizer setPlaying:playing];
#endif
}

- (AVQueuePlayer *)player {
    return _player;
}

- (float)speed {
    return _speed;
}

// Untested
- (void)concatenatingInsertAll:(NSString *)catId index:(int)index sources:(NSArray *)sources shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder {
    // Find all duplicates of the identified ConcatenatingAudioSource.
    NSMutableArray *matches = [[NSMutableArray alloc] init];
    [_audioSource findById:catId matches:matches];
    // Add each new source to each match.
    for (int i = 0; i < matches.count; i++) {
        ConcatenatingAudioSource *catSource = (ConcatenatingAudioSource *)matches[i];
        int idx = index >= 0 ? index : catSource.count;
        NSMutableArray<AudioSource *> *audioSources = [self decodeAudioSources:sources];
        for (int j = 0; j < audioSources.count; j++) {
            AudioSource *audioSource = audioSources[j];
            [catSource insertSource:audioSource atIndex:(idx + j)];
        }
        [catSource setShuffleOrder:shuffleOrder];
    }
    // Index the new audio sources.
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        IndexedAudioSource *audioSource = _indexedAudioSources[i];
        if (!audioSource.isAttached) {
            audioSource.playerItem.audioSource = audioSource;
            [self addItemObservers:audioSource.playerItem];
        }
    }
    [self updateOrder];
    if (_player.currentItem) {
        _index = [self indexForItem:(IndexedPlayerItem *)_player.currentItem];
    } else {
        _index = 0;
    }
    [self enqueueFrom:_index];
    // Notify each new IndexedAudioSource that it's been attached to the player.
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        if (!_indexedAudioSources[i].isAttached) {
            [_indexedAudioSources[i] attach:_player initialPos:kCMTimeInvalid];
        }
    }
    [self broadcastPlaybackEvent];
}

// Untested
- (void)concatenatingRemoveRange:(NSString *)catId start:(int)start end:(int)end shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder {
    // Find all duplicates of the identified ConcatenatingAudioSource.
    NSMutableArray *matches = [[NSMutableArray alloc] init];
    [_audioSource findById:catId matches:matches];
    // Remove range from each match.
    for (int i = 0; i < matches.count; i++) {
        ConcatenatingAudioSource *catSource = (ConcatenatingAudioSource *)matches[i];
        int endIndex = end >= 0 ? end : catSource.count;
        [catSource removeSourcesFromIndex:start toIndex:endIndex];
        [catSource setShuffleOrder:shuffleOrder];
    }
    // Re-index the remaining audio sources.
    NSArray<IndexedAudioSource *> *oldIndexedAudioSources = _indexedAudioSources;
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    for (int i = 0, j = 0; i < _indexedAudioSources.count; i++, j++) {
        IndexedAudioSource *audioSource = _indexedAudioSources[i];
        while (audioSource != oldIndexedAudioSources[j]) {
            [self removeItemObservers:oldIndexedAudioSources[j].playerItem];
            if (oldIndexedAudioSources[j].playerItem2) {
                [self removeItemObservers:oldIndexedAudioSources[j].playerItem2];
            }
            if (j < _index) {
                _index--;
            } else if (j == _index) {
                // The currently playing item was removed.
            }
            j++;
        }
    }
    [self updateOrder];
    if (_index >= _indexedAudioSources.count) _index = (int)_indexedAudioSources.count - 1;
    if (_index < 0) _index = 0;
    [self enqueueFrom:_index];
    [self broadcastPlaybackEvent];
}

// Untested
- (void)concatenatingMove:(NSString *)catId currentIndex:(int)currentIndex newIndex:(int)newIndex shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder {
    // Find all duplicates of the identified ConcatenatingAudioSource.
    NSMutableArray *matches = [[NSMutableArray alloc] init];
    [_audioSource findById:catId matches:matches];
    // Move range within each match.
    for (int i = 0; i < matches.count; i++) {
        ConcatenatingAudioSource *catSource = (ConcatenatingAudioSource *)matches[i];
        [catSource moveSourceFromIndex:currentIndex toIndex:newIndex];
        [catSource setShuffleOrder:shuffleOrder];
    }
    // Re-index the audio sources.
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    [self updateOrder];
    [self enqueueFrom:[self indexForItem:(IndexedPlayerItem *)_player.currentItem]];
    [self broadcastPlaybackEvent];
}

- (void)checkForDiscontinuity {
    if (!_playing || CMTIME_IS_VALID(_seekPos) || _processingState == psCompleted) return;
    int position = [self getCurrentPosition];
    if (@available(macOS 10.12, iOS 10.0, *)) {
        // I45 (#526): buffering is timeControlStatus's job here. Only re-stamp the
        // position when the running clock drifted from the stamp; never enterBuffering.
        if (_processingState == psReady && position > _lastPosition && _updateTime != 0L) {
            long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
            long long expectedPosition = _updatePosition + (long long)((now - _updateTime) * _player.rate);
            if (llabs(position - expectedPosition) > kRestampDriftMs) {
                [self updatePosition];
                [self broadcastPlaybackEvent];
            }
        }
    } else if (_processingState == psBuffering) {
        if (position > _lastPosition) {
            [self leaveBuffering:@"stall ended"];
            [self updatePosition];
            [self broadcastPlaybackEvent];
        }
    } else {
        long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        long long timeSinceLastUpdate = now - _updateTime;
        long long expectedPosition = _updatePosition + (long long)(timeSinceLastUpdate * _player.rate);
        long long drift = position - expectedPosition;
        //NSLog(@"position: %d, drift: %lld", position, drift);
        // Update if we've drifted or just started observing
        if (_updateTime == 0L) {
            [self broadcastPlaybackEvent];
        } else if (drift < -100) {
            [self enterBuffering:@"stalling"];
            //NSLog(@"Drift: %lld", drift);
            [self updatePosition];
            [self broadcastPlaybackEvent];
        }
    }
    _lastPosition = position;
}

- (void)enterBuffering:(NSString *)reason {
    if (_processingState != psIdle) {
        //NSLog(@"ENTER BUFFERING: %@", reason);
        _processingState = psBuffering;
    }
}

- (void)leaveBuffering:(NSString *)reason {
    if (_processingState == psBuffering || _processingState == psLoading) {
        //NSLog(@"LEAVE BUFFERING: %@", reason);
        _processingState = psReady;
    }
}

- (void)broadcastPlaybackEvent {
    [_eventChannel sendEvent:@{
            @"processingState": @(_processingState),
            @"updatePosition": @((long long)1000 * _updatePosition),
            @"updateTime": @(_updateTime),
            @"bufferedPosition": @((long long)1000 * [self getBufferedPosition]),
            @"icyMetadata": _icyMetadata,
            @"duration": @([self getDurationMicroseconds]),
            @"currentIndex": @(_index),
            @"errorCode": _errorCode,
            @"errorMessage": _errorMessage,
    }];
}

- (int)getCurrentPosition {
    // XXX: During load, the second case will be selected returning 0.
    // TODO: Provide a similar case as _seekPos for _initialPos.
    if (CMTIME_IS_VALID(_seekPos)) {
        return (int)(1000 * CMTimeGetSeconds(_seekPos));
    } else if (_indexedAudioSources && _indexedAudioSources.count > 0) {
        int ms = (int)(1000 * CMTimeGetSeconds(_indexedAudioSources[_index].position));
        if (ms < 0) ms = 0;
        return ms;
    } else {
        return 0;
    }
}

- (int)getBufferedPosition {
    if (_processingState == psIdle || _processingState == psLoading) {
        return 0;
    } else if (_indexedAudioSources && _indexedAudioSources.count > 0) {
        int ms = (int)(1000 * CMTimeGetSeconds(_indexedAudioSources[_index].bufferedPosition));
        if (ms < 0) ms = 0;
        return ms;
    } else {
        return 0;
    }
}

- (int)getDuration {
    if (_processingState == psIdle || _processingState == psLoading) {
        return -1;
    } else if (_indexedAudioSources && _indexedAudioSources.count > 0) {
        int v = (int)(1000 * CMTimeGetSeconds(_indexedAudioSources[_index].duration));
        return v;
    } else {
        return 0;
    }
}

- (long long)getDurationMicroseconds {
    int duration = [self getDuration];
    return duration < 0 ? -1 : ((long long)1000 * duration);
}

- (void)removeItemObservers:(AVPlayerItem *)playerItem {
    [playerItem removeObserver:self forKeyPath:@"status"];
    [playerItem removeObserver:self forKeyPath:@"playbackBufferEmpty"];
    [playerItem removeObserver:self forKeyPath:@"playbackBufferFull"];
    [playerItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
    //[playerItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:playerItem];
}

- (void)addItemObservers:(AVPlayerItem *)playerItem {
    // Get notified when the item is loaded or had an error loading
    [playerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    // Get notified of the buffer state
    [playerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:NSKeyValueObservingOptionNew context:nil];
    [playerItem addObserver:self forKeyPath:@"playbackBufferFull" options:NSKeyValueObservingOptionNew context:nil];
    [playerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:nil];
    //[playerItem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:NSKeyValueObservingOptionNew context:nil];
    // Get notified when playback has reached the end
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onComplete:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    // Get notified when playback stops due to a failure (currently unused)
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onFailToComplete:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    // Get notified when playback stalls (currently unused)
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onItemStalled:) name:AVPlayerItemPlaybackStalledNotification object:playerItem];

    AVPlayerItemMetadataOutput *metadataOutput = [[AVPlayerItemMetadataOutput alloc] initWithIdentifiers:nil];
    [metadataOutput setDelegate:self queue:dispatch_get_main_queue()];
    // Since the delegate is stored as a weak reference,
    // there shouldn't be a retain cycle.
    // TODO: Check this. Shouldn't need to removeOutput
    // later?
    [playerItem addOutput:metadataOutput];
}

- (void)metadataOutput:(AVPlayerItemMetadataOutput *)output didOutputTimedMetadataGroups:(NSArray<AVTimedMetadataGroup *> *)groups fromPlayerItemTrack:(AVPlayerItemTrack *)track {
    // ICY headers aren't available here. Maybe do this in the proxy.
    BOOL hasIcyData = NO;
    NSString *title = (NSString *)[NSNull null];
    NSString *url = (NSString *)[NSNull null];
    for (int i = 0; i < groups.count; i++) {
        AVTimedMetadataGroup *group = groups[i];
        for (int j = 0; j < group.items.count; j++) {
            AVMetadataItem *item = group.items[j];
            if ([@"icy/StreamTitle" isEqualToString:item.identifier]) {
                hasIcyData = YES;
                title = (NSString *)item.value;
            } else if ([@"icy/StreamUrl" isEqualToString:item.identifier]) {
                hasIcyData = YES;
                url = (NSString *)item.value;
            }
        }
    }
    if (hasIcyData) {
        _icyMetadata = @{
            @"info": @{
                @"title": title,
                @"url": url,
            },
        };
        [self broadcastPlaybackEvent];
    }
}

- (NSMutableArray<AudioSource *> *)decodeAudioSources:(NSArray *)data {
    NSMutableArray<AudioSource *> *array = (NSMutableArray<AudioSource *> *)[[NSMutableArray alloc] init];
    for (int i = 0; i < [data count]; i++) {
        AudioSource *source = [self decodeAudioSource:data[i]];
        [array addObject:source];
    }
    return array;
}

- (AudioSource *)decodeAudioSource:(NSDictionary *)data {
    NSString *type = data[@"type"];
    if ([@"progressive" isEqualToString:type] || [@"dash" isEqualToString:type] || [@"hls" isEqualToString:type]) {
        UriAudioSource *source = [[UriAudioSource alloc] initWithId:data[@"id"] uri:data[@"uri"] loadControl:_loadControl headers:data[@"headers"] options:data[@"options"]];
        // Navis (I26): the app's ReplayGain stamp; a clip's child carries the clip's gain.
        if ([data[@"replayGainDb"] isKindOfClass:[NSNumber class]]) source.replayGainDb = data[@"replayGainDb"];
        return source;
    } else if ([@"concatenating" isEqualToString:type]) {
        return [[ConcatenatingAudioSource alloc] initWithId:data[@"id"]
                                               audioSources:[self decodeAudioSources:data[@"children"]]
                                               shuffleOrder:(NSArray<NSNumber *> *)data[@"shuffleOrder"]
                                                lazyLoading:(NSNumber *)data[@"useLazyPreparation"]];
    } else if ([@"clipping" isEqualToString:type]) {
        return [[ClippingAudioSource alloc] initWithId:data[@"id"]
                                           audioSource:(UriAudioSource *)[self decodeAudioSource:data[@"child"]]
                                                 start:data[@"start"]
                                                   end:data[@"end"]];
    } else if ([@"looping" isEqualToString:type]) {
        NSMutableArray *childSources = [NSMutableArray new];
        int count = [data[@"count"] intValue];
        for (int i = 0; i < count; i++) {
            [childSources addObject:[self decodeAudioSource:data[@"child"]]];
        }
        return [[LoopingAudioSource alloc] initWithId:data[@"id"] audioSources:childSources];
    } else {
        return nil;
    }
}

- (void)enqueueFrom:(int)index {
    //NSLog(@"### enqueueFrom:%d", index);
    _index = index;

    // Update the queue while keeping the currently playing item untouched.

    /* NSLog(@"before reorder: _player.items.count: ", _player.items.count); */
    /* [self dumpQueue]; */

    // First, remove all _player items except for the currently playing one (if any).
    IndexedPlayerItem *oldItem = (IndexedPlayerItem *)_player.currentItem;
    IndexedPlayerItem *existingItem = nil;
    IndexedPlayerItem *newItem = _indexedAudioSources.count > 0 ? _indexedAudioSources[_index].playerItem : nil;
#if TARGET_OS_IOS
    // The playing item changes and no seek, skip or load flushed for it: a queue edit removed it (the
    // next song takes over, neither a natural advance nor a seek). Decide the new song's boost and
    // flush before the queue is rebuilt, so its first block does not ramp down from the old song's gain.
    BOOL flushedByCommand = _commandFlushed;
    _commandFlushed = NO;
    if (_equalizer && oldItem && newItem && oldItem != newItem && !flushedByCommand) {
        [self noteBoostJumpToIndex:_index positionMs:NAN];
        [self noteEqualizerFlush];
    }
#endif
    NSArray *oldPlayerItems = [NSArray arrayWithArray:_player.items];
    // Navis: queued items that are already in the right order stay as they are.
    // Removing and re-inserting the prefetched next item (every append of a
    // queue fill does) restarts its audio pipeline, which breaks the gapless
    // join to it. Only while the playing item stays first and not looping.
    NSMutableSet<AVPlayerItem *> *kept = [NSMutableSet set];
#if TARGET_OS_IOS
    if (_loopMode == lmLoopOff && newItem && oldPlayerItems.count > 0 && oldPlayerItems[0] == newItem) {
        BOOL inOrder = NO;
        NSUInteger matched = 0;
        for (int i = 0; i < [_order count]; i++) {
            int si = [_order[i] intValue];
            if (si == _index) inOrder = YES;
            if (!inOrder) continue;
            AVPlayerItem *wanted = _indexedAudioSources[si].playerItem;
            if (matched >= oldPlayerItems.count || oldPlayerItems[matched] != wanted) break;
            [kept addObject:wanted];
            matched++;
        }
    }
#endif
    // In the first pass, preserve the old and new items.
    for (int i = 0; i < oldPlayerItems.count; i++) {
        if (oldPlayerItems[i] == newItem) {
            // Preserve and tag new item if it is already in the queue.
            existingItem = oldPlayerItems[i];
            //NSLog(@"Preserving existing item %d", [self indexForItem:existingItem]);
        } else if ([kept containsObject:oldPlayerItems[i]]) {
            // Navis: already queued in the right order.
        } else if (oldPlayerItems[i] == oldItem) {
            //NSLog(@"Preserving old item %d", [self indexForItem:oldItem]);
            // Temporarily preserve old item, just to avoid jumping to
            // intermediate queue positions unnecessarily. We only want to jump
            // once to _index.
        } else {
            //NSLog(@"Removing item %d", [self indexForItem:oldPlayerItems[i]]);
            [_player removeItem:oldPlayerItems[i]];
        }
    }
    // In the second pass, remove the old item (if different from new item).
    if (oldItem && newItem != oldItem) {
        //NSLog(@"removing old item %d", [self indexForItem:oldItem]);
        [_player removeItem:oldItem];
    }

    /* NSLog(@"inter order: _player.items.count: ", _player.items.count); */
    /* [self dumpQueue]; */

    // Regenerate queue
    _enqueuedAll = NO;
    if (!existingItem || _loopMode != lmLoopOne) {
        _enqueuedAll = YES;
        BOOL include = NO;
        for (int i = 0; i < [_order count]; i++) {
            int si = [_order[i] intValue];
            if (si == _index) include = YES;
            if (include && _indexedAudioSources[si].playerItem != existingItem
                && ![kept containsObject:_indexedAudioSources[si].playerItem]) {
                if (_indexedAudioSources[si].lazyLoading && _player.items.count >= TREADMILL_SIZE) {
                    // Enqueue up until the first lazy item that does not fit on the treadmill.
                    _enqueuedAll = NO;
                    break;
                }
                //NSLog(@"inserting item %d", si);
                [self insertQueueItem:_indexedAudioSources[si].playerItem];
                if (_loopMode == lmLoopOne) {
                    // We only want one item in the queue.
                    break;
                }
            }
        }
    }

    // Add next loop item if we're looping
    if (_order.count > 0) {
        if (_loopMode == lmLoopAll && _enqueuedAll) {
            int si = [_order[0] intValue];
            //NSLog(@"### add loop item:%d", si);
            if (!_indexedAudioSources[si].playerItem2) {
                [_indexedAudioSources[si] preparePlayerItem2];
                [self addItemObservers:_indexedAudioSources[si].playerItem2];
            }
            [self insertQueueItem:_indexedAudioSources[si].playerItem2];
        } else if (_loopMode == lmLoopOne) {
            //NSLog(@"### add loop item:%d", _index);
            if (!_indexedAudioSources[_index].playerItem2) {
                [_indexedAudioSources[_index] preparePlayerItem2];
                [self addItemObservers:_indexedAudioSources[_index].playerItem2];
            }
            [self insertQueueItem:_indexedAudioSources[_index].playerItem2];
        }
    }

    /* NSLog(@"after reorder: _player.items.count: ", _player.items.count); */
    /* [self dumpQueue]; */
    [self attachEqualizerToQueueKeeping:existingItem];
    [self noteBoostQueueChanged];

    if (_processingState != psLoading && oldItem != newItem) {
        // || !_player.currentItem.playbackLikelyToKeepUp;
        if (_player.currentItem.playbackBufferEmpty) {
            [self enterBuffering:@"enqueueFrom playbackBufferEmpty"];
        } else {
            [self leaveBuffering:@"enqueueFrom !playbackBufferEmpty"];
        }
        [self updatePosition];
    }

    [self updateEndAction];
}

- (void)updatePosition {
    _updatePosition = [self getCurrentPosition];
    _updateTime = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

- (void)load:(NSDictionary *)source initialPosition:(CMTime)initialPosition initialIndex:(NSNumber *)initialIndex result:(FlutterResult)result {
    [self noteBoostLoad]; // before the flush
    [self noteEqualizerFlush];
    _commandFlushed = YES; // enqueueFrom: below need not flush again
    if (_playing) {
        [_player pause];
    }
    if (_processingState == psLoading) {
        [self abortExistingConnection:NO];
    }
    _loadResult = result;
    _processingState = psLoading;
    _index = (initialIndex != (id)[NSNull null]) ? [initialIndex intValue] : 0;
    _errorCode = (NSNumber *)[NSNull null];
    _errorMessage = (NSString *)[NSNull null];
    // Remove previous observers
    if (_indexedAudioSources) {
        for (int i = 0; i < [_indexedAudioSources count]; i++) {
            [self removeItemObservers:_indexedAudioSources[i].playerItem];
            if (_indexedAudioSources[i].playerItem2) {
                [self removeItemObservers:_indexedAudioSources[i].playerItem2];
            }
        }
    }
    // Decode audio source
    if (_audioSource && [@"clipping" isEqualToString:source[@"type"]]) {
        // Check if we're clipping an audio source that was previously loaded.
        UriAudioSource *child = nil;
        if ([_audioSource isKindOfClass:[ClippingAudioSource class]]) {
            ClippingAudioSource *clipper = (ClippingAudioSource *)_audioSource;
            child = clipper.audioSource;
        } else if ([_audioSource isKindOfClass:[UriAudioSource class]]) {
            child = (UriAudioSource *)_audioSource;
        }
        NSString *type = source[@"child"][@"type"];
        NSString *uri = nil;
        if ([@"progressive" isEqualToString:type] || [@"dash" isEqualToString:type] || [@"hls" isEqualToString:type]) {
            uri = source[@"child"][@"uri"];
        }
        if (child && uri && [child.uri isEqualToString:uri]) {
            ClippingAudioSource *clipper =
                [[ClippingAudioSource alloc] initWithId:source[@"id"]
                                            audioSource:child
                                                  start:source[@"start"]
                                                    end:source[@"end"]];
            clipper.playerItem.audioSource = clipper;
            if (clipper.playerItem2) {
                clipper.playerItem2.audioSource = clipper;
            }
            _audioSource = clipper;
        } else {
            _audioSource = [self decodeAudioSource:source];
        }
    } else {
        _audioSource = [self decodeAudioSource:source];
    }
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        IndexedAudioSource *source = _indexedAudioSources[i];
        [self addItemObservers:source.playerItem];
        source.playerItem.audioSource = source;
    }
    [self updatePosition];
    [self updateOrder];
    // Set up an empty player
    if (!_player) {
        _player = [[AVQueuePlayer alloc] initWithItems:@[]];
        if (@available(macOS 10.12, iOS 10.0, *)) {
            _player.automaticallyWaitsToMinimizeStalling = _automaticallyWaitsToMinimizeStalling;
            // TODO: Remove these observers in dispose.
            [_player addObserver:self
                      forKeyPath:@"timeControlStatus"
                         options:NSKeyValueObservingOptionNew
                         context:nil];
        }
        if (@available(macOS 10.11, iOS 6.0, *)) {
            _player.allowsExternalPlayback = _allowsExternalPlayback;
        }
        [_player addObserver:self
                  forKeyPath:@"currentItem"
                     options:NSKeyValueObservingOptionNew
                     context:nil];
        // TODO: learn about the different ways to define weakSelf.
        //__weak __typeof__(self) weakSelf = self;
        //typeof(self) __weak weakSelf = self;
        __unsafe_unretained typeof(self) weakSelf = self;
        // ponytail: 200 ms polling; a boundary observer if battery shows it.
        _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(200, 1000)
                                                              queue:nil
                                                         usingBlock:^(CMTime time) {
                                                             [weakSelf checkForDiscontinuity];
                                                         }
        ];
    }
    // Initialise the AVQueuePlayer with items.
    [self enqueueFrom:_index];
    // Notify each IndexedAudioSource that it's been attached to the player.
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_indexedAudioSources[i] attach:_player initialPos:(i == _index ? initialPosition : kCMTimeInvalid)];
    }

    if (_playing) {
        _player.rate = _speed;
    }
    [_player setVolume:_volume];
    [self broadcastPlaybackEvent];

#if TARGET_OS_IOS
    [self updateBoostObserver];
#endif
    if (_loadResult && (_indexedAudioSources.count == 0 || !_player.currentItem ||
            _player.currentItem.status == AVPlayerItemStatusReadyToPlay)) {
        _processingState = psReady;
        _loadResult(@{@"duration": @([self getDurationMicroseconds])});
        _loadResult = nil;
    } else {
        // We send result after the playerItem is ready in observeValueForKeyPath.
    }
    /* NSLog(@"load:"); */
    /* for (int i = 0; i < [_indexedAudioSources count]; i++) { */
    /*     NSLog(@"- %@", _indexedAudioSources[i].sourceId); */
    /* } */
}

- (void)updateOrder {
    _orderInv = [NSMutableArray arrayWithCapacity:[_indexedAudioSources count]];
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_orderInv addObject:@(0)];
    }
    if (_shuffleModeEnabled) {
        _order = [_audioSource getShuffleIndices];
    } else {
        NSMutableArray *order = [[NSMutableArray alloc] init];
        for (int i = 0; i < [_indexedAudioSources count]; i++) {
            [order addObject:@(i)];
        }
        _order = order;
    }
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        _orderInv[[_order[i] intValue]] = @(i);
    }
}

- (void)onItemStalled:(NSNotification *)notification {
    //IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
    //NSLog(@"onItemStalled");
}

- (void)onFailToComplete:(NSNotification *)notification {
    //IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
    //NSLog(@"onFailToComplete");
}

- (void)onComplete:(NSNotification *)notification {
    //NSLog(@"onComplete");

    IndexedPlayerItem *endedPlayerItem = (IndexedPlayerItem *)notification.object;
    IndexedAudioSource *endedSource = endedPlayerItem.audioSource;

    if (_loopMode == lmLoopOne) {
        [endedSource seek:kCMTimeZero];
        _justAdvanced = YES;
    } else if (_loopMode == lmLoopAll) {
        [endedSource seek:kCMTimeZero];
        _index = [_order[([_orderInv[_index] intValue] + 1) % _order.count] intValue];
        [self broadcastPlaybackEvent];
        _justAdvanced = YES;
    } else if ([_orderInv[_index] intValue] + 1 < [_order count]) {
        [endedSource seek:kCMTimeZero];
        _index = [_order[([_orderInv[_index] intValue] + 1)] intValue];
        [self updateEndAction];
        [self broadcastPlaybackEvent];
        _justAdvanced = YES;
    } else {
        // reached end of playlist
        [self complete];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSString *,id> *)change
                       context:(void *)context {

    if ([keyPath isEqualToString:@"status"]) {
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)object;
        AVPlayerItemStatus status = AVPlayerItemStatusUnknown;
        NSNumber *statusNumber = change[NSKeyValueChangeNewKey];
        if ([statusNumber isKindOfClass:[NSNumber class]]) {
            status = statusNumber.intValue;
        }
        [playerItem.audioSource onStatusChanged:status];
        switch (status) {
            case AVPlayerItemStatusReadyToPlay: {
                if (playerItem != _player.currentItem) return;
                // Detect buffering in different ways depending on whether we're playing
                if (_playing) {
                    if (@available(macOS 10.12, iOS 10.0, *)) {
                        if (_player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) {
                            [self enterBuffering:@"ready to play: playing, waitingToPlay"];
                        } else {
                            [self leaveBuffering:@"ready to play: playing, !waitingToPlay"];
                        }
                        [self updatePosition];
                    } else {
                        // If this happens when we're playing, check whether buffer is confirmed
                        if (_bufferUnconfirmed && !_player.currentItem.playbackBufferFull) {
                            // Stay in bufering - XXX Test
                            [self enterBuffering:@"ready to play: playing, bufferUnconfirmed && !playbackBufferFull"];
                        } else {
                            if (_player.currentItem.playbackBufferEmpty) {
                                // !_player.currentItem.playbackLikelyToKeepUp;
                                [self enterBuffering:@"ready to play: playing, playbackBufferEmpty"];
                            } else {
                                [self leaveBuffering:@"ready to play: playing, !playbackBufferEmpty"];
                            }
                            [self updatePosition];
                        }
                    }
                } else {
                    if (_player.currentItem.playbackBufferEmpty) {
                        [self enterBuffering:@"ready to play: !playing, playbackBufferEmpty"];
                        // || !_player.currentItem.playbackLikelyToKeepUp;
                    } else {
                        [self leaveBuffering:@"ready to play: !playing, !playbackBufferEmpty"];
                    }
                    [self updatePosition];
                }
                [self broadcastPlaybackEvent];
                if (_loadResult) {
                    _loadResult(@{@"duration": @([self getDurationMicroseconds])});
                    _loadResult = nil;
                }
                break;
            }
            case AVPlayerItemStatusFailed: {
                //NSLog(@"AVPlayerItemStatusFailed on item [%d]", [self indexForItem:playerItem]);
                if (playerItem == _player.currentItem) {
                    [self sendErrorForItem:playerItem];
                }
                break;
            }
            case AVPlayerItemStatusUnknown:
                break;
        }
    } else if ([keyPath isEqualToString:@"playbackBufferEmpty"] || [keyPath isEqualToString:@"playbackBufferFull"]) {
        // Use these values to detect buffering.
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)object;
        if (playerItem != _player.currentItem) return;
        // If there's a seek in progress, these values are unreliable
        if (CMTIME_IS_VALID(_seekPos)) return;
        // Detect buffering in different ways depending on whether we're playing
        if (_playing) {
            if (@available(macOS 10.12, iOS 10.0, *)) {
                // We handle this with timeControlStatus instead.
            } else {
                if (_bufferUnconfirmed && playerItem.playbackBufferFull) {
                    _bufferUnconfirmed = NO;
                    [self leaveBuffering:@"playing, _bufferUnconfirmed && playbackBufferFull"];
                    [self updatePosition];
                    //NSLog(@"Buffering confirmed! leaving buffering");
                    [self broadcastPlaybackEvent];
                }
            }
        } else {
            if (playerItem.playbackBufferEmpty) {
                [self enterBuffering:@"!playing, playbackBufferEmpty"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
            } else if (!playerItem.playbackBufferEmpty || playerItem.playbackBufferFull) {
                [self leaveBuffering:@"!playing, !playbackBufferEmpty || playbackBufferFull"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
            }
        }
    /* } else if ([keyPath isEqualToString:@"playbackLikelyToKeepUp"]) { */
    } else if ([keyPath isEqualToString:@"timeControlStatus"]) {
        if (@available(macOS 10.12, iOS 10.0, *)) {
            AVPlayerTimeControlStatus status = AVPlayerTimeControlStatusPaused;
            NSNumber *statusNumber = change[NSKeyValueChangeNewKey];
            if ([statusNumber isKindOfClass:[NSNumber class]]) {
                status = statusNumber.intValue;
            }
            switch (status) {
                case AVPlayerTimeControlStatusPaused:
                    //NSLog(@"AVPlayerTimeControlStatusPaused");
                    break;
                case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                    //NSLog(@"AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate");
                    if (_processingState != psCompleted) {
                        [self enterBuffering:@"timeControlStatus"];
                        [self updatePosition];
                        [self broadcastPlaybackEvent];
                    } else {
                        //NSLog(@"Ignoring wait signal because we reached the end");
                    }
                    break;
                case AVPlayerTimeControlStatusPlaying:
                    [self leaveBuffering:@"timeControlStatus"];
                    [self updatePosition];
                    [self broadcastPlaybackEvent];
                    break;
            }
        }
    } else if ([keyPath isEqualToString:@"currentItem"] && _player.currentItem) {
        //NSLog(@"currentItem -> [%d]", [self indexForItem:_player.currentItem]);
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)change[NSKeyValueChangeNewKey];
        //IndexedPlayerItem *oldPlayerItem = (IndexedPlayerItem *)change[NSKeyValueChangeOldKey];
        if (playerItem.status == AVPlayerItemStatusFailed) {
            [self sendErrorForItem:playerItem];
            return;
        } else {
            int expectedIndex = [self indexForItem:playerItem];
            if (_index != expectedIndex) {
                // AVQueuePlayer will sometimes skip over error items without
                // notifying this observer.
                //NSLog(@"Queue change detected. Adjusting index from %d -> %d", _index, expectedIndex);
                _index = expectedIndex;
                [self updateEndAction];
                [self broadcastPlaybackEvent];
            }
        }
        //NSLog(@"currentItem changed. _index=%d", _index);
        _bufferUnconfirmed = YES;
        [self noteBoostQueueChanged];
        // If we've skipped or transitioned to a new item and we're not
        // currently in the middle of a seek
        /* if (CMTIME_IS_INVALID(_seekPos) && playerItem.status == AVPlayerItemStatusReadyToPlay) { */
        /*     [self updatePosition]; */
        /*     IndexedAudioSource *source = playerItem.audioSource; */
        /*     // We should already be at position zero but for */
        /*     // ClippingAudioSource it might be off by some milliseconds so we */
        /*     // consider anything <= 100 as close enough. */
        /*     if ((int)(1000 * CMTimeGetSeconds(source.position)) > 100) { */
        /*         NSLog(@"On currentItem change, seeking back to zero"); */
        /*         BOOL shouldResumePlayback = NO; */
        /*         AVPlayerActionAtItemEnd originalEndAction = _player.actionAtItemEnd; */
        /*         if (_playing && CMTimeGetSeconds(CMTimeSubtract(source.position, source.duration)) >= 0) { */
        /*             NSLog(@"Need to pause while rewinding because we're at the end"); */
        /*             shouldResumePlayback = YES; */
        /*             _player.actionAtItemEnd = AVPlayerActionAtItemEndPause; */
        /*             [_player pause]; */
        /*         } */
        /*         [self enterBuffering:@"currentItem changed, seeking"]; */
        /*         [self updatePosition]; */
        /*         [self broadcastPlaybackEvent]; */
        /*         __weak __typeof__(self) weakSelf = self; */
        /*         [source seek:kCMTimeZero completionHandler:^(BOOL finished) { */
        /*             [weakSelf leaveBuffering:@"currentItem changed, finished seek"]; */
        /*             [weakSelf updatePosition]; */
        /*             [weakSelf broadcastPlaybackEvent]; */
        /*             if (shouldResumePlayback) { */
        /*                 weakSelf.player.actionAtItemEnd = originalEndAction; */
        /*                 // TODO: This logic is almost duplicated in seek. See if we can reuse this code. */
        /*                 weakSelf.player.rate = weakSelf.speed; */
        /*             } */
        /*         }]; */
        /*     } else { */
        /*         // Already at zero, no need to seek. */
        /*     } */
        /* } */

        if (_justAdvanced) {
            IndexedAudioSource *audioSource = playerItem.audioSource;
            if (_loopMode == lmLoopOne) {
                [audioSource flip];
                [self enqueueFrom:_index];
            } else if (_loopMode == lmLoopAll) {
                if (_index == [_order[0] intValue] && playerItem == audioSource.playerItem2) {
                    [audioSource flip];
                    [self enqueueFrom:_index];
                } else if (!_enqueuedAll) {
                    [self enqueueFrom:_index];
                } else {
                    [self updateEndAction];
                }
            } else if (!_enqueuedAll) {
                [self enqueueFrom:_index];
            }
            _justAdvanced = NO;
        }
    } else if ([keyPath isEqualToString:@"loadedTimeRanges"]) {
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)object;
        if (playerItem != _player.currentItem) return;
        int pos = [self getBufferedPosition];
        if (pos != _bufferedPosition) {
            _bufferedPosition = pos;
            [self broadcastPlaybackEvent];
        }
    }
}

- (void)sendErrorForItem:(IndexedPlayerItem *)playerItem {
    [self sendError:@((int)playerItem.error.code) errorMessage:playerItem.error.localizedDescription playerItem:playerItem switchToIdle:YES];
    [_player removeAllItems];
}

- (void)sendError:(NSNumber *)errorCode errorMessage:(NSString *)errorMessage playerItem:(IndexedPlayerItem *)playerItem switchToIdle:(BOOL)switchToIdle {
    //NSLog(@"sendError (%@) %@", errorCode, errorMessage);
    FlutterError *flutterError = [FlutterError errorWithCode:[NSString stringWithFormat:@"%@", errorCode]
                                                     message:errorMessage
                                                     details:playerItem != nil ? @{@"index": @([self indexForItem:playerItem])} : nil];
    [_eventChannel sendEvent:flutterError];
    _errorCode = errorCode;
    _errorMessage = errorMessage;
    if (switchToIdle) {
        _processingState = psIdle;
    }
    [self broadcastPlaybackEvent];
    if (_loadResult && playerItem == _player.currentItem) {
        _loadResult(flutterError);
        _loadResult = nil;
    }
}

- (void)abortExistingConnection:(BOOL)switchToIdle {
    [self sendError:@(ERROR_ABORT) errorMessage:@"Connection aborted" playerItem:nil switchToIdle:switchToIdle];
}

- (int)indexForItem:(IndexedPlayerItem *)playerItem {
    for (int i = 0; i < _indexedAudioSources.count; i++) {
        if (_indexedAudioSources[i].playerItem == playerItem || _indexedAudioSources[i].playerItem2 == playerItem) {
            return i;
        }
    }
    return -1;
}

- (void)play {
    [self play:nil];
}

- (void)play:(FlutterResult)result {
    if (_playing) {
        if (result) {
            result(@{});
        }
        return;
    }
    if (result) {
        if (_playResult) {
            //NSLog(@"INTERRUPTING PLAY");
            _playResult(@{});
        }
        _playResult = result;
    }
    _playing = YES;
    [self noteEqualizerPlaying:YES];
    _player.rate = _speed;
    [self updatePosition];
    if (@available(macOS 10.12, iOS 10.0, *)) {}
    else {
        if (_bufferUnconfirmed && !_player.currentItem.playbackBufferFull) {
            [self enterBuffering:@"play, _bufferUnconfirmed && !playbackBufferFull"];
            [self broadcastPlaybackEvent];
        }
    }
}

- (void)pause {
    if (!_playing) return;
    _playing = NO;
    [self noteEqualizerPlaying:NO];
    [_player pause];
    [self updatePosition];
    [self broadcastPlaybackEvent];
    if (_playResult) {
        //NSLog(@"PLAY FINISHED DUE TO PAUSE");
        _playResult(@{});
        _playResult = nil;
    }
}

- (void)complete {
    [self updatePosition];
    _processingState = psCompleted;
    [self broadcastPlaybackEvent];
    if (_playResult) {
        //NSLog(@"PLAY FINISHED DUE TO COMPLETE");
        _playResult(@{});
        _playResult = nil;
    }
}

- (void)setVolume:(float)volume {
    _volume = volume;
    if (_player) {
        [_player setVolume:volume];
    }
}

- (void)setSpeed:(float)speed {
    // NOTE: We ideally should check _player.currentItem.canPlaySlowForward and
    // canPlayFastForward, but these properties are unreliable and the official
    // documentation is unclear and contradictory.
    //
    // Source #1:
    // https://developer.apple.com/documentation/avfoundation/avplayer/1388846-rate?language=objc
    //
    //     Rates other than 0.0 and 1.0 can be used if the associated player
    //     item returns YES for the AVPlayerItem properties canPlaySlowForward
    //     or canPlayFastForward.
    //
    // Source #2:
    // https://developer.apple.com/library/archive/qa/qa1772/_index.html
    //
    //     An AVPlayerItem whose status property equals
    //     AVPlayerItemStatusReadyToPlay can be played at rates between 1.0 and
    //     2.0, inclusive, even if AVPlayerItem.canPlayFastForward is NO.
    //     AVPlayerItem.canPlayFastForward indicates whether the item can be
    //     played at rates greater than 2.0.
    //
    // But in practice, it appears that even if AVPlayerItem.canPlayFastForward
    // is NO, rates greater than 2.0 still work sometimes.
    //
    // So for now, we just let the app pass in any speed and hope for the best.
    // There is no way to reliably query whether the requested speed is
    // supported.
    _speed = speed;
    if (_playing && _player) {
        _player.rate = speed;
    }
    [self updatePosition];
    [self refreshReplayGainBoost];
#if TARGET_OS_IOS
    [self scheduleRatePlan];
#endif
}

- (void)setLoopMode:(int)loopMode {
    if (loopMode == _loopMode) return;
    _loopMode = loopMode;
    [self enqueueFrom:_index];
}

- (void)updateEndAction {
    // Should be called in the following situations:
    // - when the audio source changes
    // - when _index changes
    // - when the loop mode changes.
    // - when the shuffle order changes. (TODO)
    // - when the shuffle mode changes.
    if (!_player) return;
    if (_audioSource && (_loopMode != lmLoopOff || ([_order count] > 0 && [_orderInv[_index] intValue] + 1 < [_order count]))) {
        _player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    } else {
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause; // AVPlayerActionAtItemEndNone
    }
}

- (void)setShuffleModeEnabled:(BOOL)shuffleModeEnabled {
    //NSLog(@"setShuffleModeEnabled: %d", shuffleModeEnabled);
    _shuffleModeEnabled = shuffleModeEnabled;
    if (!_audioSource) return;

    [self updateOrder];

    [self enqueueFrom:_index];
}

- (void)setShuffleOrder:(NSDictionary *)dict {
    if (!_audioSource) return;

    [_audioSource decodeShuffleOrder:dict];

    [self updateOrder];

    [self enqueueFrom:_index];
}

- (void)dumpQueue {
    for (int i = 0; i < _player.items.count; i++) {
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)_player.items[i];
        int j = [self indexForItem:playerItem];
        NSLog(@"- %d", j);
    }
}

- (void)setAutomaticallyWaitsToMinimizeStalling:(bool)automaticallyWaitsToMinimizeStalling {
    _automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling;
    if (@available(macOS 10.12, iOS 10.0, *)) {
        if(_player) {
            _player.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling;
        }
    }
}

- (void)setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)enabled {
    _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused = enabled;
    if (!_indexedAudioSources) return;
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_indexedAudioSources[i] applyCanUseNetworkResourcesForLiveStreamingWhilePaused];
    }
}

- (void)setPreferredPeakBitRate:(NSNumber *)preferredPeakBitRate {
    _loadControl.preferredPeakBitRate = preferredPeakBitRate;
    if (!_indexedAudioSources) return;
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_indexedAudioSources[i] applyPreferredPeakBitRate];
    }
}

- (void)setAllowsExternalPlayback:(BOOL)allowsExternalPlayback {
    _allowsExternalPlayback = allowsExternalPlayback;
    if (@available(macOS 10.11, iOS 6.0, *)) {
        if (_player) {
            _player.allowsExternalPlayback = allowsExternalPlayback;
        }
    }
}

- (void)seek:(CMTime)position index:(NSNumber *)newIndex completionHandler:(void (^)(BOOL))completionHandler {
    if (_processingState == psIdle || _processingState == psLoading) {
        if (completionHandler) {
            completionHandler(NO);
        }
        return;
    }
    // A user seek or skip (also the first half of a jump to another item).
    [self noteBoostSeekToIndex:newIndex position:position]; // before the flush
    [self noteEqualizerFlush];
    int index = _index;
    if (newIndex != (id)[NSNull null]) {
        index = [newIndex intValue];
    }
    if (index != _index) {
        // Jump to a new item
        /* if (_playing && index == _index + 1) { */
        /*     // Special case for jumping to the very next item */
        /*     NSLog(@"seek to next item: %d -> %d", _index, index); */
        /*     [_indexedAudioSources[_index] seek:kCMTimeZero]; */
        /*     _index = index; */
        /*     [_player advanceToNextItem]; */
        /*     [self broadcastPlaybackEvent]; */
        /* } else */
        {
            // Jump to a distant item
            //NSLog(@"seek# jump to distant item: %d -> %d", _index, index);
            if (_playing) {
                [_player pause];
            }
            [_indexedAudioSources[_index] seek:kCMTimeZero];
            // The "currentItem" key observer will respect that a seek is already in progress
            _seekPos = position;
            [self updatePosition];
            _commandFlushed = YES; // this jump flushed already
            [self enqueueFrom:index];
            IndexedAudioSource *source = _indexedAudioSources[_index];
            if (abs((int)(1000 * CMTimeGetSeconds(CMTimeSubtract(source.position, position)))) > 100) {
                [self enterBuffering:@"seek to index"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
                [source seek:position completionHandler:^(BOOL finished) {
                    if (@available(macOS 10.12, iOS 10.0, *)) {
                        if (self->_playing) {
                            // Handled by timeControlStatus
                        } else {
                            if (self->_bufferUnconfirmed && !self->_player.currentItem.playbackBufferFull) {
                                // Stay in buffering
                            } else if (source.playerItem.status == AVPlayerItemStatusReadyToPlay) {
                                [self leaveBuffering:@"seek to index finished, (!bufferUnconfirmed || playbackBufferFull) && ready to play"];
                                [self updatePosition];
                                [self broadcastPlaybackEvent];
                            }
                        }
                    } else {
                        if (self->_bufferUnconfirmed && !self->_player.currentItem.playbackBufferFull) {
                            // Stay in buffering
                        } else if (source.playerItem.status == AVPlayerItemStatusReadyToPlay) {
                            [self leaveBuffering:@"seek to index finished, (!bufferUnconfirmed || playbackBufferFull) && ready to play"];
                            [self updatePosition];
                            [self broadcastPlaybackEvent];
                        }
                    }
                    if (self->_playing) {
                        self->_player.rate = self->_speed;
                    }
                    self->_seekPos = kCMTimeInvalid;
                    [self broadcastPlaybackEvent];
                    if (completionHandler) {
                        completionHandler(finished);
                    }
                }];
            } else {
                _seekPos = kCMTimeInvalid;
                if (_playing) {
                    if (@available(iOS 10.0, *)) {
                        // NOTE: Re-enable this line only after figuring out
                        // how to detect buffering when buffered audio is not
                        // immediately available.
                        //[_player playImmediatelyAtRate:_speed];
                        _player.rate = _speed;
                    } else {
                        _player.rate = _speed;
                    }
                }
                [self broadcastPlaybackEvent];
                completionHandler(YES);
            }
        }
    } else {
        // Seek within an item
        if (_playing) {
            [_player pause];
        }
        _seekPos = position;
        //NSLog(@"seek. enter buffering. pos = %d", (int)(1000*CMTimeGetSeconds(_indexedAudioSources[_index].position)));
        // TODO: Move this into a separate method so it can also
        // be used in skip.
        [self enterBuffering:@"seek"];
        [self updatePosition];
        [self broadcastPlaybackEvent];
        [_indexedAudioSources[_index] seek:position completionHandler:^(BOOL finished) {
            [self updatePosition];
            if (self->_playing) {
                // If playing, buffering will be detected either by:
                // 1. checkForDiscontinuity
                // 2. timeControlStatus
                if (@available(iOS 10.0, *)) {
                    // NOTE: Re-enable this line only after figuring out how to
                    // detect buffering when buffered audio is not immediately
                    // available.
                    //[_player playImmediatelyAtRate:_speed];
                    self->_player.rate = self->_speed;
                } else {
                    self->_player.rate = self->_speed;
                }
            } else {
                // If not playing, there is no reliable way to detect
                // when buffering has completed, so we use
                // !playbackBufferEmpty. Although this always seems to
                // be full even right after a seek.
                if (self->_player.currentItem.playbackBufferEmpty) {
                    [self enterBuffering:@"seek finished, playbackBufferEmpty"];
                } else {
                    [self leaveBuffering:@"seek finished, !playbackBufferEmpty"];
                }
                [self updatePosition];
                if (self->_processingState != psBuffering) {
                    [self broadcastPlaybackEvent];
                }
            }
            self->_seekPos = kCMTimeInvalid;
            [self broadcastPlaybackEvent];
            if (completionHandler) {
                completionHandler(finished);
            }
        }];
    }
}

- (void)dispose:(BOOL)calledFromDealloc {
    if (!_player) return;
    if (_processingState != psIdle) {
        [_player pause];

        [self updatePosition];
        if (!calledFromDealloc) {
            [self broadcastPlaybackEvent];
        }
        if (_playResult) {
            //NSLog(@"PLAY FINISHED DUE TO STOP");
            _playResult(@{});
            _playResult = nil;
        }

        _processingState = psIdle;
        // If used just before destroying the current FlutterEngine, this will result in:
        // NSInternalInconsistencyException: 'Sending a message before the FlutterEngine has been run.'
        //[self broadcastPlaybackEvent];
    }
    if (_timeObserver) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = 0;
    }
#if TARGET_OS_IOS
    _boostMapPositive = NO;
    [self updateBoostObserver];
    _boostEvents++; // cancels a pending rise
#endif
    if (_indexedAudioSources) {
        for (int i = 0; i < [_indexedAudioSources count]; i++) {
            [self removeItemObservers:_indexedAudioSources[i].playerItem];
            if (_indexedAudioSources[i].playerItem2) {
                [self removeItemObservers:_indexedAudioSources[i].playerItem2];
            }
        }
        _indexedAudioSources = nil;
    }
    _audioSource = nil;
    if (_player) {
        [_player removeObserver:self forKeyPath:@"currentItem"];
        if (@available(macOS 10.12, iOS 10.0, *)) {
            [_player removeObserver:self forKeyPath:@"timeControlStatus"];
        }
        _player = nil;
    }
    // Untested:
#if TARGET_OS_IOS
    [_equalizer dispose];
    _equalizer = nil;
#endif
    [_eventChannel dispose];
    [_dataEventChannel dispose];
    [_methodChannel setMethodCallHandler:nil];
}

@end
