/// A validated parametric filter passed to an audio backend.
class EqualizerFilterMessage {
  const EqualizerFilterMessage({
    required this.type,
    required this.frequencyHz,
    required this.gainDb,
    required this.q,
    required this.enabled,
  });

  final String type;
  final double frequencyHz;
  final double gainDb;
  final double q;
  final bool enabled;

  Map<String, Object> toMap() => {
        'type': type,
        'frequencyHz': frequencyHz,
        'gainDb': gainDb,
        'q': q,
        'enabled': enabled,
      };
}

/// An app-owned configuration; mode/preset identity stays above the backend.
class EqualizerConfigurationMessage {
  EqualizerConfigurationMessage({
    required this.enabled,
    required this.preampDb,
    required this.autoHeadroom,
    required List<EqualizerFilterMessage> filters,
    this.diagnostics = false,
  }) : filters = List.unmodifiable(filters);

  /// Lets the Darwin player run its transition gap meter (a main-thread timer
  /// while playing). Set only in builds that can run the diagnostics API.
  final bool diagnostics;

  final bool enabled;
  final double preampDb;
  final bool autoHeadroom;
  final List<EqualizerFilterMessage> filters;

  Map<String, Object> toMap() => {
        'enabled': enabled,
        'preampDb': preampDb,
        'autoHeadroom': autoHeadroom,
        'filters': filters.map((filter) => filter.toMap()).toList(),
        if (diagnostics) 'diagnostics': true,
      };
}

/// One audio format of the queue as the Darwin tap sees it (I25): the tap keeps
/// an equalizer stream per format, so every song runs at its own rate.
class EqualizerFormatStreamMessage {
  const EqualizerFormatStreamMessage({
    required this.sampleRate,
    required this.channels,
    required this.processedFrames,
    this.levelDeltaDb,
  });

  final int sampleRate;
  final int channels;
  final int processedFrames;

  /// Output-minus-input level in dB over recent audio of this format; null
  /// before any.
  final double? levelDeltaDb;

  static EqualizerFormatStreamMessage fromMap(Map<dynamic, dynamic> map) =>
      EqualizerFormatStreamMessage(
        sampleRate: (map['sampleRate'] as num).toInt(),
        channels: (map['channels'] as num).toInt(),
        processedFrames: (map['processedFrames'] as num).toInt(),
        levelDeltaDb: (map['levelDeltaDb'] as num?)?.toDouble(),
      );

  Map<String, Object?> toJson() => {
        'sampleRate': sampleRate,
        'channels': channels,
        'processedFrames': processedFrames,
        'levelDeltaDb': levelDeltaDb,
      };
}

/// Reports actual processing availability, separately from the desired values.
class EqualizerStateMessage {
  const EqualizerStateMessage({
    required this.enabled,
    this.sampleRate,
    this.responseSampleRate,
    this.headroomDb = 0,
    this.reason,
    this.pending = false,
    this.boostRequestedDb = 0,
    this.boostAppliedDb = 0,
    this.boostClipSamples = 0,
    this.boostGuarded = false,
    this.processedFrames,
    this.levelDeltaDb,
    this.resetCount,
    this.tapPrepareCount,
    this.flushCount,
    this.transitionGapsMs,
    this.pitchCents,
    this.pitchActive,
    this.pitchLatencyFrames,
    this.pitchResetCount,
    this.pitchInputHz,
    this.pitchOutputHz,
    this.pitchPullMismatches,
    this.pitchReason,
    this.formatStreams,
    this.unmatchedFrames,
    this.overlapBlocks,
    this.livePipelines,
    this.prepareCalls,
    this.unprepareCalls,
    this.clampedUnprepares,
  });

  final bool enabled;
  final double? sampleRate;
  final double? responseSampleRate;
  final double headroomDb;
  final String? reason;
  final bool pending;

  /// The ReplayGain boost the app asked the processor for and the gain it
  /// applies now (dB), and how many samples hit the 16-bit clamp (Android) or
  /// went beyond full scale (iOS) while a boost was on. Only the Android
  /// processor and the iOS tap have a boost stage. [boostGuarded] (iOS) says
  /// the value is lowered for the song that follows.
  final double boostRequestedDb;
  final double boostAppliedDb;
  final int boostClipSamples;
  final bool boostGuarded;

  /// Frames the backend's equalizer has processed since the player started
  /// (Darwin only; null elsewhere). Grows while audio plays.
  final int? processedFrames;

  /// Output-minus-input level in dB over a recent window of played audio
  /// (Darwin only; null elsewhere or before any audio has played).
  final double? levelDeltaDb;

  /// Times the equalizer dropped its filter history because playback started,
  /// resumed or jumped (Darwin only; null elsewhere), for diagnostics.
  final int? resetCount;

  /// Times the player's shared tap was prepared (Darwin only), for diagnostics:
  /// once per audio pipeline, which AVQueuePlayer starts for each run of
  /// queued songs with the same source format (rate, channels, sample type or
  /// codec), so 1 for a queue of one format and 3 for 22.05, 48 and 96 kHz.
  final int? tapPrepareCount;

  /// Seeks and skips the player told the equalizer about (Darwin only,
  /// diagnostics); each one drops the filter history once.
  final int? flushCount;

  /// The last silences between songs in milliseconds, measured on the player's
  /// clock (Darwin only, diagnostics): about 0 when playback is gapless.
  final List<double>? transitionGapsMs;

  /// The native pitch stage (Darwin only, diagnostics): requested cents,
  /// whether it processes, its latency in frames, its resets and the
  /// zero-crossing frequency of its input and output.
  final int? pitchCents;
  final bool? pitchActive;
  final int? pitchLatencyFrames;
  final int? pitchResetCount;
  final double? pitchInputHz;
  final double? pitchOutputHz;

  /// Input pulls of the pitch unit whose size differed from the block (zero
  /// filled; expected 0) and why the tap cannot pitch its audio, if it cannot.
  final int? pitchPullMismatches;
  final String? pitchReason;

  /// One entry per audio format of the queue (Darwin only, diagnostics); the
  /// top-level rate, level and pitch fields describe the format that processed
  /// the last block.
  final List<EqualizerFormatStreamMessage>? formatStreams;

  /// Audio frames no format took and blocks passed dry because another render
  /// thread held their format (Darwin only, diagnostics); both 0 when healthy.
  final int? unmatchedFrames;
  final int? overlapBlocks;

  /// The balance of the audio pipelines that prepared and unprepared the tap
  /// (Darwin only, diagnostics): those live now, every call, and the unprepares
  /// that matched no live pipeline (0 when healthy). Starting over at the format
  /// cap is only safe while the calls balance.
  final int? livePipelines;
  final int? prepareCalls;
  final int? unprepareCalls;
  final int? clampedUnprepares;

  static EqualizerStateMessage fromMap(Map<dynamic, dynamic> map) =>
      EqualizerStateMessage(
        enabled: map['enabled'] as bool,
        sampleRate: (map['sampleRate'] as num?)?.toDouble(),
        responseSampleRate: (map['responseSampleRate'] as num?)?.toDouble(),
        headroomDb: (map['headroomDb'] as num?)?.toDouble() ?? 0,
        reason: map['reason'] as String?,
        pending: map['pending'] as bool? ?? false,
        boostRequestedDb: (map['boostRequestedDb'] as num?)?.toDouble() ?? 0,
        boostAppliedDb: (map['boostAppliedDb'] as num?)?.toDouble() ?? 0,
        boostClipSamples: (map['boostClipSamples'] as num?)?.toInt() ?? 0,
        boostGuarded: map['boostGuarded'] as bool? ?? false,
        processedFrames: (map['processedFrames'] as num?)?.toInt(),
        levelDeltaDb: (map['levelDeltaDb'] as num?)?.toDouble(),
        resetCount: (map['resetCount'] as num?)?.toInt(),
        tapPrepareCount: (map['tapPrepareCount'] as num?)?.toInt(),
        flushCount: (map['flushCount'] as num?)?.toInt(),
        transitionGapsMs: (map['transitionGapsMs'] as List<dynamic>?)
            ?.map((gap) => (gap as num).toDouble())
            .toList(growable: false),
        pitchCents: (map['pitchCents'] as num?)?.toInt(),
        pitchActive: map['pitchActive'] as bool?,
        pitchLatencyFrames: (map['pitchLatencyFrames'] as num?)?.toInt(),
        pitchResetCount: (map['pitchResetCount'] as num?)?.toInt(),
        pitchInputHz: (map['pitchInputHz'] as num?)?.toDouble(),
        pitchOutputHz: (map['pitchOutputHz'] as num?)?.toDouble(),
        pitchPullMismatches: (map['pitchPullMismatches'] as num?)?.toInt(),
        pitchReason: map['pitchReason'] as String?,
        formatStreams: (map['formatStreams'] as List<dynamic>?)
            ?.map(
              (stream) => EqualizerFormatStreamMessage.fromMap(
                stream as Map<dynamic, dynamic>,
              ),
            )
            .toList(growable: false),
        unmatchedFrames: (map['unmatchedFrames'] as num?)?.toInt(),
        overlapBlocks: (map['overlapBlocks'] as num?)?.toInt(),
        livePipelines: (map['livePipelines'] as num?)?.toInt(),
        prepareCalls: (map['prepareCalls'] as num?)?.toInt(),
        unprepareCalls: (map['unprepareCalls'] as num?)?.toInt(),
        clampedUnprepares: (map['clampedUnprepares'] as num?)?.toInt(),
      );
}

/// The ReplayGain boost (positive gain) the backend applies on top of the
/// player volume, which only ever turns songs down.
///
/// [currentDb] is the boost of the song that is playing now. [byUri] holds the
/// boost of every queued song by its source URI, for backends that switch
/// gain per file (desktop mpv). Both are 0 or more.
class SetReplayGainBoostRequest {
  const SetReplayGainBoostRequest({
    required this.currentDb,
    this.guarded = false,
    this.index,
    this.byUri = const <String, double>{},
  });

  final double currentDb;

  /// Whether the caller wants [currentDb] to be a lowered value that may only
  /// go down until the next song starts.
  final bool guarded;

  /// The queue index [currentDb] was computed for. A backend that can tell
  /// which song it is playing ignores a non-zero value for another one: a
  /// message that raced a song switch must not put the old song's boost on the
  /// new song's samples.
  final int? index;
  final Map<String, double> byUri;

  Map<String, Object?> toMap() => {
        'currentDb': currentDb,
        'guarded': guarded,
        'index': index,
        'byUri': byUri,
      };

  @override
  bool operator ==(Object other) =>
      other is SetReplayGainBoostRequest &&
      other.currentDb == currentDb &&
      other.guarded == guarded &&
      other.index == index &&
      other.byUri.length == byUri.length &&
      byUri.entries.every((entry) => other.byUri[entry.key] == entry.value);

  @override
  int get hashCode => Object.hash(currentDb, guarded, index, byUri.length);
}
