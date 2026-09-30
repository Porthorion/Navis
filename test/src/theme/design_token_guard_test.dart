import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ratchet for literal styling values that bypass the design tokens.
///
/// Each file may contain at most its recorded count of each pattern. New
/// literals fail the test; removing literals also fails until the baseline is
/// lowered, so cleanups cannot silently regress later. Regenerate with:
///
/// ```bash
/// NAVIS_UPDATE_TOKEN_BASELINE=1 flutter test test/src/theme/design_token_guard_test.dart
/// ```
const String _baselinePath = 'test/src/theme/design_token_baseline.json';

final Map<String, RegExp> _patterns = <String, RegExp>{
  // Use NavisRadius steps (or the cover-shape preference for artwork).
  'radius': RegExp(r'(?:BorderRadius|Radius)\.circular\(\s*\d'),
  // Use a TextTheme slot.
  'fontSize': RegExp(r'fontSize:\s*\d'),
  // Use a ColorScheme role or a NavisTokens surface role.
  'colorLiteral': RegExp(r'Color\(0x'),
  // Palette colours ignore the user's theme; black/white/transparent remain
  // allowed for artwork scrims and overlays.
  'paletteColor': RegExp(
    r'(?<![A-Za-z_])Colors\.(?!black\b|white\b|transparent\b)[a-z]',
  ),
};

bool _isScanned(String path) {
  final normalized = path.replaceAll(r'\', '/');
  return normalized.endsWith('.dart') &&
      !normalized.endsWith('.g.dart') &&
      !normalized.endsWith('.freezed.dart') &&
      // Token definitions and preset seed colours legitimately use literals.
      !normalized.startsWith('lib/src/theme/');
}

Map<String, Map<String, int>> _measure() {
  final counts = <String, Map<String, int>>{};
  final files =
      Directory('lib/src')
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.path.replaceAll(r'\', '/'))
          .where(_isScanned)
          .toList()
        ..sort();
  for (final path in files) {
    final content = File(path).readAsStringSync();
    final fileCounts = <String, int>{};
    for (final entry in _patterns.entries) {
      final count = entry.value.allMatches(content).length;
      if (count > 0) {
        fileCounts[entry.key] = count;
      }
    }
    if (fileCounts.isNotEmpty) {
      counts[path] = fileCounts;
    }
  }
  return counts;
}

void main() {
  test('styling literals stay within the design-token baseline', () {
    final actual = _measure();
    final baselineFile = File(_baselinePath);

    if (Platform.environment['NAVIS_UPDATE_TOKEN_BASELINE'] == '1') {
      const encoder = JsonEncoder.withIndent('  ');
      baselineFile.writeAsStringSync('${encoder.convert(actual)}\n');
      return;
    }

    final decoded =
        jsonDecode(baselineFile.readAsStringSync()) as Map<String, dynamic>;
    final baseline = <String, Map<String, int>>{
      for (final entry in decoded.entries)
        entry.key: (entry.value as Map<String, dynamic>).map(
          (key, value) => MapEntry(key, value as int),
        ),
    };

    final increases = <String>[];
    final decreases = <String>[];
    final paths = <String>{...baseline.keys, ...actual.keys}.toList()..sort();
    for (final path in paths) {
      for (final pattern in _patterns.keys) {
        final allowed = baseline[path]?[pattern] ?? 0;
        final found = actual[path]?[pattern] ?? 0;
        if (found > allowed) {
          increases.add('$path: $pattern $found > $allowed');
        } else if (found < allowed) {
          decreases.add('$path: $pattern $found < $allowed');
        }
      }
    }

    expect(
      increases,
      isEmpty,
      reason:
          'New styling literals bypass the design tokens. Use NavisSpace, '
          'NavisRadius, TextTheme slots, ColorScheme roles or NavisTokens '
          'instead.',
    );
    expect(
      decreases,
      isEmpty,
      reason:
          'Literals were removed; lower the baseline so they cannot return: '
          'NAVIS_UPDATE_TOKEN_BASELINE=1 flutter test '
          'test/src/theme/design_token_guard_test.dart',
    );
  });
}
