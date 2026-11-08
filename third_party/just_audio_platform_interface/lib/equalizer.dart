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

/// An update of the in-pipeline ReplayGain of queued songs: one signed dB
/// value (cut and boost together) per entry. Each song's first value travels
/// with its source message; this only changes values later.
///
/// [byId] holds the value of every queued entry by its source id (Android,
/// iOS); [byUri] holds the same by the URI the entry loads from (desktop mpv,
/// which switches gain per file). An entry missing from both plays at 0 dB.
///
/// The playing entry's value is frozen natively at its boundary: a message
/// changes it only when [live] is true, which the caller sets for a settings
/// change (mode, pre-amp, untagged level).
class SetReplayGainLevelsRequest {
  const SetReplayGainLevelsRequest({
    this.byId = const <String, double>{},
    this.byUri = const <String, double>{},
    this.live = false,
  });

  final Map<String, double> byId;
  final Map<String, double> byUri;
  final bool live;

  Map<String, Object?> toMap() => {
        'byId': byId,
        'byUri': byUri,
        'live': live,
      };

  static bool _same(Map<String, double> a, Map<String, double> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  @override
  bool operator ==(Object other) =>
      other is SetReplayGainLevelsRequest &&
      other.live == live &&
      _same(other.byId, byId) &&
      _same(other.byUri, byUri);

  @override
  int get hashCode => Object.hash(live, byId.length, byUri.length);
}
