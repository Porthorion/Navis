import 'dart:math' as math;

import 'package:flutter/foundation.dart';

enum EqMode { simple, tenBand, advanced, importedFixed }

enum EqFilterType { peaking, lowShelf, highShelf, lowPass, highPass, notch }

@immutable
class EqFilter {
  const new({
    this.type = EqFilterType.peaking,
    required this.frequencyHz,
    this.gainDb = 0,
    this.q = 1,
    this.enabled = true,
  });

  final EqFilterType type;
  final double frequencyHz;
  final double gainDb;
  final double q;
  final bool enabled;

  bool get usesGain => switch (type) {
    EqFilterType.peaking ||
    EqFilterType.lowShelf ||
    EqFilterType.highShelf => true,
    _ => false,
  };

  bool get isValid =>
      frequencyHz.isFinite &&
      frequencyHz >= 20 &&
      frequencyHz <= 20000 &&
      gainDb.isFinite &&
      gainDb >= -24 &&
      gainDb <= 24 &&
      q.isFinite &&
      q >= 0.1 &&
      q <= 20;

  EqFilter copyWith({
    EqFilterType? type,
    double? frequencyHz,
    double? gainDb,
    double? q,
    bool? enabled,
  }) => EqFilter(
    type: type ?? this.type,
    frequencyHz: frequencyHz ?? this.frequencyHz,
    gainDb: gainDb ?? this.gainDb,
    q: q ?? this.q,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object> toJson() => {
    'type': type.name,
    'frequencyHz': frequencyHz,
    'gainDb': gainDb,
    'q': q,
    'enabled': enabled,
  };

  static EqFilter fromJson(Map<String, dynamic> json) {
    final filter = EqFilter(
      type: EqFilterType.values.byName(json['type'] as String),
      frequencyHz: (json['frequencyHz'] as num).toDouble(),
      gainDb: (json['gainDb'] as num).toDouble(),
      q: (json['q'] as num).toDouble(),
      enabled: json['enabled'] as bool,
    );
    if (!filter.isValid) throw const FormatException('Invalid EQ filter.');
    return filter;
  }

  @override
  bool operator ==(Object other) =>
      other is EqFilter &&
      type == other.type &&
      frequencyHz == other.frequencyHz &&
      gainDb == other.gainDb &&
      q == other.q &&
      enabled == other.enabled;

  @override
  int get hashCode => Object.hash(type, frequencyHz, gainDb, q, enabled);
}

@immutable
class EqConfiguration {
  new({
    this.enabled = false,
    this.mode = EqMode.simple,
    this.preampDb = 0,
    this.autoHeadroom = true,
    required List<EqFilter> filters,
  }) : filters = List.unmodifiable(filters);

  factory flat({EqMode mode = EqMode.simple}) => EqConfiguration(
    mode: mode,
    filters: switch (mode) {
      EqMode.simple =>
        simpleFrequencies
            .map((hz) => EqFilter(frequencyHz: hz, q: 0.67))
            .toList(),
      EqMode.tenBand => List.generate(
        10,
        (i) => EqFilter(frequencyHz: 31.25 * math.pow(2, i), q: math.sqrt(2)),
      ),
      EqMode.advanced || EqMode.importedFixed => const [],
    },
  );

  static const schemaVersion = 1;
  static const maximumFilters = 32;
  static const simpleFrequencies = <double>[63, 250, 1000, 4000, 16000];

  final bool enabled;
  final EqMode mode;
  final double preampDb;
  final bool autoHeadroom;
  final List<EqFilter> filters;

  bool get isValid {
    if (!preampDb.isFinite ||
        preampDb < -60 ||
        preampDb > 24 ||
        filters.length > maximumFilters ||
        filters.any((filter) => !filter.isValid)) {
      return false;
    }
    final expected = switch (mode) {
      EqMode.simple => EqConfiguration.flat(),
      EqMode.tenBand => EqConfiguration.flat(mode: EqMode.tenBand),
      _ => null,
    };
    if (mode == EqMode.importedFixed &&
        filters.any((f) => f.type != EqFilterType.peaking)) {
      return false;
    }
    if (expected == null) return true;
    if (filters.length != expected.filters.length) return false;
    for (var i = 0; i < filters.length; i++) {
      final filter = filters[i];
      final reference = expected.filters[i];
      if (filter.type != EqFilterType.peaking ||
          filter.frequencyHz != reference.frequencyHz ||
          filter.q != reference.q) {
        return false;
      }
    }
    return true;
  }

  bool supportsSampleRate(double sampleRate) =>
      sampleRate.isFinite &&
      sampleRate > 0 &&
      filters.every(
        (filter) => !filter.enabled || filter.frequencyHz < sampleRate / 2,
      );

  bool get isFlat =>
      preampDb == 0 &&
      filters.every(
        (filter) => !filter.enabled || (filter.usesGain && filter.gainDb == 0),
      );

  EqConfiguration copyWith({
    bool? enabled,
    EqMode? mode,
    double? preampDb,
    bool? autoHeadroom,
    List<EqFilter>? filters,
  }) => EqConfiguration(
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    preampDb: preampDb ?? this.preampDb,
    autoHeadroom: autoHeadroom ?? this.autoHeadroom,
    filters: filters ?? this.filters,
  );

  /// Switching to Advanced preserves filters; fixed modes start a new curve.
  EqConfiguration changeMode(EqMode next) {
    if (next == mode) return this;
    if (next == EqMode.advanced) return copyWith(mode: next);
    return EqConfiguration.flat(mode: next).copyWith(enabled: enabled);
  }

  Map<String, Object> toJson() => {
    'version': schemaVersion,
    'enabled': enabled,
    'mode': mode.name,
    'preampDb': preampDb,
    'autoHeadroom': autoHeadroom,
    'filters': filters.map((filter) => filter.toJson()).toList(),
  };

  static EqConfiguration fromJson(Map<String, dynamic> json) {
    if (json['version'] != schemaVersion) {
      throw const FormatException('Unsupported EQ configuration version.');
    }
    final configuration = EqConfiguration(
      enabled: json['enabled'] as bool,
      mode: EqMode.values.byName(json['mode'] as String),
      preampDb: (json['preampDb'] as num).toDouble(),
      autoHeadroom: json['autoHeadroom'] as bool,
      filters: (json['filters'] as List<dynamic>)
          .map((raw) => EqFilter.fromJson(raw as Map<String, dynamic>))
          .toList(),
    );
    if (!configuration.isValid) {
      throw const FormatException('Invalid EQ configuration.');
    }
    return configuration;
  }

  @override
  bool operator ==(Object other) =>
      other is EqConfiguration &&
      enabled == other.enabled &&
      mode == other.mode &&
      preampDb == other.preampDb &&
      autoHeadroom == other.autoHeadroom &&
      listEquals(filters, other.filters);

  @override
  int get hashCode => Object.hash(
    enabled,
    mode,
    preampDb,
    autoHeadroom,
    Object.hashAll(filters),
  );
}

@immutable
class EqSource {
  const new({
    required this.originalText,
    this.url,
    this.revision,
    this.measurementSource,
    this.target,
  });

  factory fromJson(Map<String, dynamic> json) => EqSource(
    originalText: json['originalText'] as String,
    url: json['url'] as String?,
    revision: json['revision'] as String?,
    measurementSource: json['measurementSource'] as String?,
    target: json['target'] as String?,
  );

  final String originalText;
  final String? url;
  final String? revision;
  final String? measurementSource;
  final String? target;

  Map<String, Object?> toJson() => {
    'originalText': originalText,
    'url': url,
    'revision': revision,
    'measurementSource': measurementSource,
    'target': target,
  };
}

@immutable
class EqPreset {
  const new({
    required this.id,
    required this.name,
    required this.configuration,
    this.source,
    this.builtIn = false,
  });

  factory fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'navis-eq' || json['version'] != 1) {
      throw const FormatException('Unsupported Navis EQ preset format.');
    }
    final id = json['id'] as String;
    final name = (json['name'] as String).trim();
    if (id.isEmpty || name.isEmpty || name.length > 120) {
      throw const FormatException('Invalid EQ preset identity.');
    }
    return EqPreset(
      id: id,
      name: name,
      configuration: EqConfiguration.fromJson(
        json['configuration'] as Map<String, dynamic>,
      ),
      source: json['source'] == null
          ? null
          : EqSource.fromJson(json['source'] as Map<String, dynamic>),
    );
  }

  final String id;
  final String name;
  final EqConfiguration configuration;
  final EqSource? source;
  final bool builtIn;

  static List<EqPreset> get builtIns {
    final flat = EqConfiguration.flat();
    EqConfiguration gains(List<double> values) => flat.copyWith(
      filters: List.generate(
        values.length,
        (i) => flat.filters[i].copyWith(gainDb: values[i]),
      ),
    );
    return [
      EqPreset(
        id: 'builtin:flat',
        name: 'Flat',
        configuration: flat,
        builtIn: true,
      ),
      EqPreset(
        id: 'builtin:bass',
        name: 'Bass boost',
        configuration: gains([3, 2, 0, 0, 0]),
        builtIn: true,
      ),
      EqPreset(
        id: 'builtin:vocal',
        name: 'Vocal clarity',
        configuration: gains([-2, -1, 2, 2, 0]),
        builtIn: true,
      ),
    ];
  }

  EqPreset copyWith({
    String? id,
    String? name,
    EqConfiguration? configuration,
  }) => EqPreset(
    id: id ?? this.id,
    name: name ?? this.name,
    configuration: configuration ?? this.configuration,
    source: source,
    builtIn: builtIn,
  );

  Map<String, Object?> toJson() => {
    'format': 'navis-eq',
    'version': 1,
    'id': id,
    'name': name,
    'configuration': configuration.toJson(),
    if (source != null) 'source': source!.toJson(),
  };
}

@immutable
class EqCapabilities {
  const new({required this.supported, this.reason});

  static const unavailable = EqCapabilities(
    supported: false,
    reason: 'Equalizer is unavailable with the current audio engine.',
  );
  static const available = EqCapabilities(supported: true);

  final bool supported;
  final String? reason;
}

@immutable
class EqApplicationState {
  const new({
    required this.desired,
    required this.applied,
    this.sampleRate,
    this.responseSampleRate,
    this.headroomDb = 0,
    this.reason,
    this.pending = false,
  });

  final EqConfiguration desired;
  final EqConfiguration applied;
  final double? sampleRate;
  final double? responseSampleRate;
  final double headroomDb;
  final String? reason;
  final bool pending;
}
