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
  }) : filters = List.unmodifiable(filters);

  final bool enabled;
  final double preampDb;
  final bool autoHeadroom;
  final List<EqualizerFilterMessage> filters;

  Map<String, Object> toMap() => {
        'enabled': enabled,
        'preampDb': preampDb,
        'autoHeadroom': autoHeadroom,
        'filters': filters.map((filter) => filter.toMap()).toList(),
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
  });

  final bool enabled;
  final double? sampleRate;
  final double? responseSampleRate;
  final double headroomDb;
  final String? reason;
  final bool pending;

  /// The ReplayGain boost the app asked the processor for and the gain it
  /// applies now (dB), and how many samples hit the 16-bit clamp while a
  /// boost was on. Only the Android processor has a boost stage.
  final double boostRequestedDb;
  final double boostAppliedDb;
  final int boostClipSamples;

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
    this.byUri = const <String, double>{},
  });

  final double currentDb;

  /// Whether the caller wants [currentDb] to be a lowered value that may only
  /// go down until the next song starts.
  final bool guarded;
  final Map<String, double> byUri;

  Map<String, Object> toMap() => {
        'currentDb': currentDb,
        'guarded': guarded,
        'byUri': byUri,
      };

  @override
  bool operator ==(Object other) =>
      other is SetReplayGainBoostRequest &&
      other.currentDb == currentDb &&
      other.guarded == guarded &&
      other.byUri.length == byUri.length &&
      byUri.entries.every((entry) => other.byUri[entry.key] == entry.value);

  @override
  int get hashCode => Object.hash(currentDb, guarded, byUri.length);
}
