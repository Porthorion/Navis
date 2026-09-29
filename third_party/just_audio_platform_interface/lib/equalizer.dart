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
  });

  final bool enabled;
  final double? sampleRate;
  final double? responseSampleRate;
  final double headroomDb;
  final String? reason;
  final bool pending;

  static EqualizerStateMessage fromMap(Map<dynamic, dynamic> map) =>
      EqualizerStateMessage(
        enabled: map['enabled'] as bool,
        sampleRate: (map['sampleRate'] as num?)?.toDouble(),
        responseSampleRate: (map['responseSampleRate'] as num?)?.toDouble(),
        headroomDb: (map['headroomDb'] as num?)?.toDouble() ?? 0,
        reason: map['reason'] as String?,
        pending: map['pending'] as bool? ?? false,
      );
}
