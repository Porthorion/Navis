import 'dart:convert';

import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

class EqImportParser {
  static const maximumBytes = 1024 * 1024;
  static const _number = r'([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)';
  static final _preamp = RegExp(
    '^Preamp:\\s*$_number\\s+dB\\s*\$',
    caseSensitive: false,
  );
  static final _filter = RegExp(
    r'^Filter\s+(\d+):\s+(ON|OFF)\s+(PK|LSC|HSC)\s+'
    'Fc\\s+$_number\\s+Hz\\s+Gain\\s+$_number\\s+dB\\s+'
    'Q\\s+$_number\\s*\$',
    caseSensitive: false,
  );

  EqPreset parse(
    String text, {
    required String id,
    required String name,
    bool fixedBand = false,
    String? sourceUrl,
    String? revision,
    String? measurementSource,
    String? target,
  }) {
    if (utf8.encode(text).length > maximumBytes) {
      throw const FormatException('EQ imports must be smaller than 1 MB.');
    }
    final trimmed = text.replaceFirst('\uFEFF', '').trim();
    if (trimmed.isEmpty) throw const FormatException('The EQ file is empty.');
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        final preset = EqPreset.fromJson(decoded as Map<String, dynamic>);
        return preset.copyWith(id: id);
      } on Object {
        throw const FormatException('Invalid or unsupported Navis EQ preset.');
      }
    }
    if (trimmed.toLowerCase().startsWith('graphiceq:')) {
      throw const FormatException(
        'GraphicEQ curves are not supported. Download ParametricEQ.txt '
        'or FixedBandEQ.txt from AutoEQ instead.',
      );
    }
    if (name.trim().isEmpty || name.trim().length > 120) {
      throw const FormatException('Enter a preset name of 1–120 characters.');
    }
    double? preamp;
    final filters = <EqFilter>[];
    final filterNumbers = <int>{};
    final lines = const LineSplitter().convert(trimmed);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].split('#').first.trim();
      if (line.isEmpty) continue;
      final preampMatch = _preamp.firstMatch(line);
      if (preampMatch != null) {
        if (preamp != null) {
          throw FormatException('Duplicate preamp on line ${i + 1}.');
        }
        preamp = double.parse(preampMatch.group(1)!);
        continue;
      }
      final match = _filter.firstMatch(line);
      if (match == null) {
        throw FormatException('Unsupported EQ instruction on line ${i + 1}.');
      }
      final number = int.parse(match.group(1)!);
      if (number <= 0 || !filterNumbers.add(number)) {
        throw FormatException('Invalid or duplicate filter on line ${i + 1}.');
      }
      filters.add(
        EqFilter(
          type: switch (match.group(3)!.toUpperCase()) {
            'PK' => EqFilterType.peaking,
            'LSC' => EqFilterType.lowShelf,
            'HSC' => EqFilterType.highShelf,
            _ => throw const FormatException('Unsupported filter type.'),
          },
          frequencyHz: double.parse(match.group(4)!),
          gainDb: double.parse(match.group(5)!),
          q: double.parse(match.group(6)!),
          enabled: match.group(2)!.toUpperCase() == 'ON',
        ),
      );
      if (!filters.last.isValid ||
          filters.length > EqConfiguration.maximumFilters) {
        throw FormatException('Filter is outside supported limits: ${i + 1}.');
      }
    }
    if (preamp == null || filters.isEmpty) {
      throw const FormatException(
        'A preamp and at least one filter are required.',
      );
    }
    if (fixedBand && filters.any((f) => f.type != EqFilterType.peaking)) {
      throw const FormatException(
        'Fixed-band profiles require peaking filters.',
      );
    }
    final configuration = EqConfiguration(
      mode: fixedBand ? EqMode.importedFixed : EqMode.advanced,
      preampDb: preamp,
      filters: filters,
    );
    if (!configuration.isValid) {
      throw const FormatException('Preamp is outside the supported range.');
    }
    return EqPreset(
      id: id,
      name: name.trim(),
      configuration: configuration,
      source: EqSource(
        originalText: text,
        url: sourceUrl,
        revision: revision,
        measurementSource: measurementSource,
        target: target,
      ),
    );
  }
}
