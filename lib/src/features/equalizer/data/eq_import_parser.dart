import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:navis/src/features/equalizer/data/eq_import/eq_import_decoder.dart';
import 'package:navis/src/features/equalizer/data/eq_import/eq_import_result.dart';
import 'package:navis/src/features/equalizer/data/eq_import/graphic_eq_fitter.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

export 'package:navis/src/features/equalizer/data/eq_import/eq_import_result.dart';

/// Reads EQ presets from every format Navis supports into one [EqPreset].
///
/// Formats are recognised by content, never by file name: Navis preset JSON,
/// EasyEffects equalizer JSON, GraphicEQ curves (AutoEQ, Wavelet), and the
/// Equalizer APO filter language used by AutoEQ ParametricEQ/FixedBandEQ,
/// REW exports and APO configs. Unsupported but harmless content produces a
/// warning; anything that would change the sound incorrectly is an error.
class EqImportParser {
  static const maximumBytes = eqImportMaximumBytes;

  /// AutoEQ FixedBandEQ frequencies.
  static const _fixedBandFrequencies = <double>[
    31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000, //
  ];

  /// Reads [bytes] in any supported text encoding; see [parseText].
  EqImportResult parseBytes(
    Uint8List bytes, {
    required String id,
    required String name,
    bool? fixedBand,
    String? sourceUrl,
    String? revision,
    String? measurementSource,
    String? target,
  }) => parseText(
    decodeEqImportBytes(bytes),
    id: id,
    name: name,
    fixedBand: fixedBand,
    sourceUrl: sourceUrl,
    revision: revision,
    measurementSource: measurementSource,
    target: target,
  );

  /// Parses [text]. [name] names the preset unless the file carries its own
  /// (Navis JSON). [fixedBand] forces (true) or forbids (false) the
  /// fixed-band layout; when null it is detected from the filters.
  EqImportResult parseText(
    String text, {
    required String id,
    required String name,
    bool? fixedBand,
    String? sourceUrl,
    String? revision,
    String? measurementSource,
    String? target,
  }) {
    if (utf8.encode(text).length > maximumBytes) {
      throw EqImportException(EqImportErrorCode.tooLarge);
    }
    final trimmed = text.replaceAll('﻿', '').trim();
    if (trimmed.isEmpty) throw EqImportException(EqImportErrorCode.empty);
    final source = EqSource(
      originalText: text,
      url: sourceUrl,
      revision: revision,
      measurementSource: measurementSource,
      target: target,
    );
    if (trimmed.startsWith('{')) {
      return _parseJson(trimmed, id: id, name: name, source: source);
    }
    final presetName = name.trim();
    if (presetName.isEmpty || presetName.length > 120) {
      throw EqImportException(EqImportErrorCode.invalidName);
    }
    return _parseFilters(
      trimmed,
      id: id,
      name: presetName,
      fixedBand: fixedBand,
      source: source,
    );
  }

  /// Compatibility entry point returning only the preset.
  EqPreset parse(
    String text, {
    required String id,
    required String name,
    bool? fixedBand,
    String? sourceUrl,
    String? revision,
    String? measurementSource,
    String? target,
  }) => parseText(
    text,
    id: id,
    name: name,
    fixedBand: fixedBand,
    sourceUrl: sourceUrl,
    revision: revision,
    measurementSource: measurementSource,
    target: target,
  ).preset;

  // ---------------------------------------------------------------------------
  // Equalizer APO filter language (AutoEQ, REW, APO) and GraphicEQ.
  // ---------------------------------------------------------------------------

  static final _numberPattern = RegExp(
    r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$',
  );
  static final _decimalComma = RegExp(r'(\d),(\d)');
  static final _filterLine = RegExp(
    r'^Filter(?:\s*\d+)?\s*:\s*(.*)$',
    caseSensitive: false,
  );
  static final _directive = RegExp(r'^([A-Za-z]+)\s*:\s*(.*)$');
  static const _ignoredDirectives = <String>{
    'device', 'include', 'copy', 'stage', 'delay', 'convolution', 'eval', //
    'if', 'elseif', 'else', 'endif', 'loudnesscorrection', 'comment',
    'equaliser', 'equalizer', 'notes', 'dated', 'average',
  };

  EqImportResult _parseFilters(
    String text, {
    required String id,
    required String name,
    required bool? fixedBand,
    required EqSource source,
  }) {
    final warnings = <EqImportWarning>[];
    var preamp = 0.0;
    var preampLines = 0;
    final filters = <EqFilter>[];
    final graphicPoints = <(double, double)>[];
    var graphicLine = 0;
    // REW exports start with a free-form header before the first filter.
    var rewHeader = false;
    // 0: no channel selection yet; 1: a single-channel selection is active;
    // 2: filters were added under it. A later selection would apply other
    // filters to other channels, which Navis cannot reproduce.
    var channelBlocks = 0;
    var channelsLimited = false;

    final lines = const LineSplitter().convert(text);
    for (var index = 0; index < lines.length; index++) {
      final lineNumber = index + 1;
      var line = lines[index].split('#').first.trim();
      if (line.isEmpty) continue;
      line = line.replaceAllMapped(
        _decimalComma,
        (match) => '${match.group(1)}.${match.group(2)}',
      );
      if (index == 0 && line.toLowerCase().startsWith('filter settings file')) {
        rewHeader = true;
        continue;
      }

      final filterMatch = _filterLine.firstMatch(line);
      if (filterMatch != null) {
        rewHeader = false;
        if (channelsLimited) continue;
        final filter = _parseFilterBody(
          filterMatch.group(1)!,
          lineNumber,
          warnings,
        );
        if (filter != null) {
          filters.add(filter);
          if (channelBlocks == 1) channelBlocks = 2;
        }
        continue;
      }
      if (rewHeader) continue;

      final directive = _directive.firstMatch(line);
      if (directive == null) {
        throw EqImportException(
          EqImportErrorCode.unsupportedLine,
          line: lineNumber,
        );
      }
      final key = directive.group(1)!.toLowerCase();
      final value = directive.group(2)!.trim();
      switch (key) {
        case 'preamp':
          preamp += _number(
            value.replaceFirst(RegExp(r'\s*dB$', caseSensitive: false), ''),
            lineNumber,
          );
          preampLines++;
        case 'graphiceq':
          graphicLine = lineNumber;
          for (final pair in value.split(';')) {
            final parts = pair.trim().split(RegExp(r'\s+'));
            if (parts.length == 1 && parts.single.isEmpty) continue;
            if (parts.length != 2) {
              throw EqImportException(
                EqImportErrorCode.unsupportedLine,
                line: lineNumber,
              );
            }
            graphicPoints.add((
              _number(parts[0], lineNumber),
              _number(parts[1], lineNumber),
            ));
          }
        case 'channel':
          final channels = value.toLowerCase().split(RegExp(r'\s+')).toSet();
          final both =
              channels.contains('all') ||
              (channels.contains('l') && channels.contains('r'));
          if (channelBlocks == 2) {
            channelsLimited = true;
            warnings.add(
              EqImportWarning(
                EqImportWarningCode.channelsLimited,
                line: lineNumber,
              ),
            );
          } else if (!both) {
            channelBlocks = 1;
          }
        default:
          if (!_ignoredDirectives.contains(key)) {
            throw EqImportException(
              EqImportErrorCode.unsupportedLine,
              line: lineNumber,
            );
          }
          warnings.add(
            EqImportWarning(
              EqImportWarningCode.instructionIgnored,
              line: lineNumber,
              detail: directive.group(1),
            ),
          );
      }
    }

    if (preampLines > 1) {
      warnings.add(const EqImportWarning(EqImportWarningCode.preampSummed));
    }
    if (!preamp.isFinite || preamp < -60 || preamp > 24) {
      throw EqImportException(EqImportErrorCode.invalidPreamp);
    }

    if (filters.isEmpty && graphicPoints.isNotEmpty) {
      if (graphicEqPointCount(graphicPoints) < 2) {
        throw EqImportException(
          EqImportErrorCode.graphicTooFewPoints,
          line: graphicLine,
        );
      }
      final fit = fitGraphicEq(graphicPoints);
      warnings.add(
        EqImportWarning(
          EqImportWarningCode.graphicFitted,
          detail:
              '${fit.filters.length}|${fit.rmsErrorDb.toStringAsFixed(1)}|'
              '${fit.maxErrorDb.toStringAsFixed(1)}',
        ),
      );
      return _result(
        id: id,
        name: name,
        source: source,
        format: EqImportFormat.graphic,
        configuration: EqConfiguration(
          mode: EqMode.advanced,
          preampDb: preamp,
          filters: fit.filters,
        ),
        warnings: warnings,
      );
    }
    if (graphicPoints.isNotEmpty) {
      warnings.add(
        EqImportWarning(
          EqImportWarningCode.instructionIgnored,
          line: graphicLine,
          detail: 'GraphicEQ',
        ),
      );
    }
    if (filters.isEmpty) throw EqImportException(EqImportErrorCode.noFilters);
    if (filters.length > EqConfiguration.maximumFilters) {
      throw EqImportException(EqImportErrorCode.tooManyFilters);
    }
    if (preampLines == 0) {
      warnings.add(const EqImportWarning(EqImportWarningCode.preampMissing));
    }

    final allPeaking = filters.every((f) => f.type == EqFilterType.peaking);
    if (fixedBand == true && !allPeaking) {
      throw EqImportException(EqImportErrorCode.fixedBandNeedsPeaking);
    }
    final fixed = fixedBand ?? (allPeaking && _isAutoEqFixedBand(filters));
    return _result(
      id: id,
      name: name,
      source: source,
      format: fixed ? EqImportFormat.fixedBand : EqImportFormat.parametric,
      configuration: EqConfiguration(
        mode: fixed ? EqMode.importedFixed : EqMode.advanced,
        preampDb: preamp,
        filters: filters,
      ),
      warnings: warnings,
    );
  }

  static bool _isAutoEqFixedBand(List<EqFilter> filters) {
    if (filters.length != _fixedBandFrequencies.length) return false;
    final q = filters.first.q;
    for (var i = 0; i < filters.length; i++) {
      if (filters[i].frequencyHz != _fixedBandFrequencies[i] ||
          filters[i].q != q) {
        return false;
      }
    }
    return true;
  }

  /// One `Filter:` line after the colon, e.g. `ON PK Fc 100 Hz Gain -3 dB
  /// Q 1.41`, `ON LSC 12 dB Fc 105 Hz Gain 5 dB` or `ON NO Fc 60 Hz BW Oct
  /// 0.1`. Returns null for filters that are skipped with a warning.
  EqFilter? _parseFilterBody(
    String body,
    int line,
    List<EqImportWarning> warnings,
  ) {
    final tokens = body.split(RegExp(r'\s+'));
    if (tokens.length < 2) {
      throw EqImportException(EqImportErrorCode.unsupportedLine, line: line);
    }
    final state = tokens[0].toUpperCase();
    if (state != 'ON' && state != 'OFF') {
      throw EqImportException(EqImportErrorCode.unsupportedLine, line: line);
    }
    final enabled = state == 'ON';
    final type = tokens[1].toUpperCase();
    var position = 2;

    // Optional shelf slope: "12dB" or "12 dB" before the parameters.
    double? slope;
    if (position < tokens.length) {
      final slopeToken = tokens[position];
      final joined = RegExp(
        r'^([0-9.]+)dB$',
        caseSensitive: false,
      ).firstMatch(slopeToken);
      if (joined != null) {
        slope = _number(joined.group(1)!, line);
        position++;
      } else if (_numberPattern.hasMatch(slopeToken) &&
          position + 1 < tokens.length &&
          tokens[position + 1].toLowerCase() == 'db') {
        slope = _number(slopeToken, line);
        position += 2;
      }
    }

    double? frequency;
    double? gain;
    double? q;
    double? bandwidthOctaves;
    String token(int at) {
      if (at >= tokens.length) {
        throw EqImportException(EqImportErrorCode.unsupportedLine, line: line);
      }
      return tokens[at];
    }

    bool unitAt(int at, String unit) =>
        at < tokens.length && tokens[at].toLowerCase() == unit;
    while (position < tokens.length) {
      switch (tokens[position].toLowerCase()) {
        case 'fc':
          frequency = _number(token(position + 1), line);
          position += unitAt(position + 2, 'hz') ? 3 : 2;
        case 'gain':
          gain = _number(token(position + 1), line);
          position += unitAt(position + 2, 'db') ? 3 : 2;
        case 'q':
          q = _number(token(position + 1), line);
          position += 2;
        case 'bw':
          if (token(position + 1).toLowerCase() != 'oct') {
            throw EqImportException(
              EqImportErrorCode.unsupportedLine,
              line: line,
            );
          }
          bandwidthOctaves = _number(token(position + 2), line);
          position += 3;
        default:
          throw EqImportException(
            EqImportErrorCode.unsupportedLine,
            line: line,
          );
      }
    }

    if (type == 'NONE') return null; // An empty REW slot.
    final EqFilterType? filterType;
    switch (type) {
      case 'PK' || 'PEQ':
        filterType = EqFilterType.peaking;
      case 'LS' || 'LSC' || 'LSQ':
        filterType = EqFilterType.lowShelf;
      case 'HS' || 'HSC' || 'HSQ':
        filterType = EqFilterType.highShelf;
      case 'LP' || 'LPQ':
        filterType = EqFilterType.lowPass;
      case 'HP' || 'HPQ':
        filterType = EqFilterType.highPass;
      case 'NO':
        filterType = EqFilterType.notch;
      case 'BP' || 'AP' || 'MODAL' || 'IIR':
        filterType = null;
      default:
        throw EqImportException(EqImportErrorCode.unsupportedLine, line: line);
    }
    if (filterType == null) {
      warnings.add(
        EqImportWarning(
          EqImportWarningCode.filterDropped,
          line: line,
          detail: type,
        ),
      );
      return null;
    }
    if (frequency == null) {
      throw EqImportException(EqImportErrorCode.unsupportedLine, line: line);
    }
    final usesGain =
        filterType == EqFilterType.peaking ||
        filterType == EqFilterType.lowShelf ||
        filterType == EqFilterType.highShelf;
    if (usesGain && gain == null) {
      throw EqImportException(EqImportErrorCode.unsupportedLine, line: line);
    }
    if (bandwidthOctaves != null) {
      if (bandwidthOctaves <= 0) {
        throw EqImportException(EqImportErrorCode.invalidValue, line: line);
      }
      final ratio = math.pow(2, bandwidthOctaves).toDouble();
      q ??= math.sqrt(ratio) / (ratio - 1);
    }
    if (slope != null &&
        (filterType == EqFilterType.lowShelf ||
            filterType == EqFilterType.highShelf)) {
      q ??= _shelfQForSlope(slope, gain!, line);
    }
    if (q == null) {
      if (filterType == EqFilterType.peaking) {
        throw EqImportException(EqImportErrorCode.unsupportedLine, line: line);
      }
      q = filterType == EqFilterType.notch ? 10 : math.sqrt1_2;
    }
    final filter = EqFilter(
      type: filterType,
      frequencyHz: frequency,
      gainDb: usesGain ? gain! : 0,
      q: q,
      enabled: enabled,
    );
    if (!filter.isValid) {
      throw EqImportException(EqImportErrorCode.invalidValue, line: line);
    }
    return filter;
  }

  /// RBJ cookbook shelf Q for a slope given in dB per octave (12 dB/oct is
  /// the steepest slope without overshoot, S = 1).
  static double _shelfQForSlope(double slopeDb, double gainDb, int line) {
    final s = slopeDb / 12;
    final a = math.pow(10, gainDb / 40).toDouble();
    final inner = (a + 1 / a) * (1 / s - 1) + 2;
    if (s <= 0 || inner <= 0) {
      throw EqImportException(EqImportErrorCode.invalidValue, line: line);
    }
    return 1 / math.sqrt(inner);
  }

  double _number(String token, int line) {
    if (!_numberPattern.hasMatch(token)) {
      throw EqImportException(EqImportErrorCode.unsupportedLine, line: line);
    }
    final value = double.parse(token);
    if (!value.isFinite) {
      throw EqImportException(EqImportErrorCode.invalidValue, line: line);
    }
    return value;
  }

  // ---------------------------------------------------------------------------
  // JSON: Navis presets and EasyEffects equalizer settings.
  // ---------------------------------------------------------------------------

  EqImportResult _parseJson(
    String text, {
    required String id,
    required String name,
    required EqSource source,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw EqImportException(EqImportErrorCode.unsupportedJson);
    }
    if (decoded is! Map<String, dynamic>) {
      throw EqImportException(EqImportErrorCode.unsupportedJson);
    }
    if (decoded['format'] == 'navis-eq') {
      return _parseNavisPreset(decoded, id: id, name: name);
    }
    final easyEffects = _easyEffectsEqualizer(decoded);
    if (easyEffects != null) {
      final presetName = name.trim();
      if (presetName.isEmpty || presetName.length > 120) {
        throw EqImportException(EqImportErrorCode.invalidName);
      }
      return _parseEasyEffects(
        easyEffects,
        id: id,
        name: presetName,
        source: source,
      );
    }
    throw EqImportException(EqImportErrorCode.unsupportedJson);
  }

  EqImportResult _parseNavisPreset(
    Map<String, dynamic> json, {
    required String id,
    required String name,
  }) {
    final EqPreset preset;
    try {
      final storedName = json['name'];
      preset = EqPreset.fromJson(<String, dynamic>{
        ...json,
        'id': id,
        if (storedName is! String || storedName.trim().isEmpty) 'name': name,
      });
    } on Object {
      throw EqImportException(EqImportErrorCode.invalidNavisPreset);
    }
    return EqImportResult(
      // A preset carries whatever `enabled` it was saved with; importing
      // never switches the equalizer on by itself.
      preset: preset.copyWith(
        configuration: preset.configuration.copyWith(enabled: false),
      ),
      format: EqImportFormat.navisPreset,
    );
  }

  /// The EasyEffects equalizer section of a preset or exported plugin state.
  static Map<String, dynamic>? _easyEffectsEqualizer(
    Map<String, dynamic> json,
  ) {
    Map<String, dynamic>? equalizerIn(Object? section) {
      if (section is! Map<String, dynamic>) return null;
      for (final entry in section.entries) {
        if (entry.key == 'equalizer' || entry.key.startsWith('equalizer#')) {
          final value = entry.value;
          if (value is Map<String, dynamic> && value['left'] is Map) {
            return value;
          }
        }
      }
      return null;
    }

    if (json['left'] is Map && json.containsKey('num-bands')) return json;
    return equalizerIn(json['output']) ?? equalizerIn(json);
  }

  EqImportResult _parseEasyEffects(
    Map<String, dynamic> equalizer, {
    required String id,
    required String name,
    required EqSource source,
  }) {
    final warnings = <EqImportWarning>[];
    final left = equalizer['left'] as Map<String, dynamic>;
    final count = (equalizer['num-bands'] as num?)?.toInt() ?? left.length;
    if (equalizer['split-channels'] == true) {
      warnings.add(const EqImportWarning(EqImportWarningCode.splitChannels));
    }
    double numberOf(Object? value) {
      if (value is num && value.isFinite) return value.toDouble();
      throw EqImportException(EqImportErrorCode.invalidValue);
    }

    final filters = <EqFilter>[];
    for (var band = 0; band < count; band++) {
      final raw = left['band$band'];
      if (raw is! Map<String, dynamic>) continue;
      final typeName = (raw['type'] as String? ?? 'Bell').toLowerCase();
      final EqFilterType type;
      switch (typeName) {
        case 'bell':
          type = EqFilterType.peaking;
        case 'lo-shelf' || 'low-shelf':
          type = EqFilterType.lowShelf;
        case 'hi-shelf' || 'high-shelf':
          type = EqFilterType.highShelf;
        case 'lo-pass' || 'low-pass':
          type = EqFilterType.lowPass;
        case 'hi-pass' || 'high-pass':
          type = EqFilterType.highPass;
        case 'notch':
          type = EqFilterType.notch;
        case 'off':
          continue;
        default:
          warnings.add(
            EqImportWarning(
              EqImportWarningCode.filterDropped,
              detail: typeName,
            ),
          );
          continue;
      }
      final filter = EqFilter(
        type: type,
        frequencyHz: numberOf(raw['frequency']),
        gainDb: numberOf(raw['gain'] ?? 0),
        q: numberOf(raw['q'] ?? math.sqrt1_2),
        enabled: raw['mute'] != true,
      );
      if (!filter.isValid) {
        throw EqImportException(EqImportErrorCode.invalidValue);
      }
      filters.add(filter);
    }
    if (filters.isEmpty) throw EqImportException(EqImportErrorCode.noFilters);
    if (filters.length > EqConfiguration.maximumFilters) {
      throw EqImportException(EqImportErrorCode.tooManyFilters);
    }
    final preamp =
        numberOf(equalizer['input-gain'] ?? 0) +
        numberOf(equalizer['output-gain'] ?? 0);
    if (preamp < -60 || preamp > 24) {
      throw EqImportException(EqImportErrorCode.invalidPreamp);
    }
    return _result(
      id: id,
      name: name,
      source: source,
      format: EqImportFormat.easyEffects,
      configuration: EqConfiguration(
        mode: EqMode.advanced,
        preampDb: preamp,
        filters: filters,
      ),
      warnings: warnings,
    );
  }

  EqImportResult _result({
    required String id,
    required String name,
    required EqSource source,
    required EqImportFormat format,
    required EqConfiguration configuration,
    required List<EqImportWarning> warnings,
  }) {
    if (!configuration.isValid) {
      throw EqImportException(EqImportErrorCode.invalidValue);
    }
    return EqImportResult(
      preset: EqPreset(
        id: id,
        name: name,
        configuration: configuration,
        source: source,
      ),
      format: format,
      warnings: List<EqImportWarning>.unmodifiable(warnings),
    );
  }
}
