import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every haptic goes through `NavisHaptics` so Settings -> Haptics can gate it.
/// `AdjustmentRuler` keeps its own tuned primitives, but checks
/// `NavisHaptics.allows` first.
final _raw = RegExp(r'\bHapticFeedback\.');
const _allowed = {
  'lib/src/common_widgets/navis_haptics.dart',
  'lib/src/features/player/presentation/adjustment_ruler.dart',
};

void main() {
  test('lib plays haptics only through NavisHaptics', () {
    final violations = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (f) => f.path.endsWith('.dart') && !_allowed.contains(f.path),
            )) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_raw.hasMatch(lines[i])) {
          violations.add('${file.path}:${i + 1} calls HapticFeedback');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('the ruler checks the gate before its raw haptics', () {
    final source = File(
      'lib/src/features/player/presentation/adjustment_ruler.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('NavisHaptics.allows(HapticCategory.slidersAndRulers)'),
    );
    expect(
      source,
      contains('NavisHaptics.allows(HapticCategory.switchesAndSteppers)'),
    );
  });

  test('every InkWell and ListTile long press switches off the framework '
      'vibration', () {
    // The framework vibrates on a long press unless `enableFeedback: false`,
    // which would bypass the master switch. `withLongPressHaptic` plays the
    // gated haptic instead.
    final violations = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      for (final m in _tile.allMatches(source)) {
        final args = _topLevelArgs(source, m.end - 1);
        if (args.contains('onLongPress') && !args.contains('enableFeedback')) {
          final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
          violations.add(
            '${file.path}:$line ${m.group(1)} sets onLongPress '
            'without enableFeedback: false',
          );
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}

final _tile = RegExp(r'(?<![\w.])(InkWell|InkResponse|ListTile)\(');

/// The named arguments written directly in the call whose `(` is at [open],
/// not those of nested widgets.
Set<String> _topLevelArgs(String s, int open) {
  final names = <String>{};
  final name = RegExp(r'(?:\s|//[^\n]*)*(\w+):');
  void addName(int at) {
    final n = name.matchAsPrefix(s, at + 1);
    if (n != null) names.add(n.group(1)!);
  }

  var depth = 0;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (s.startsWith('//', i)) {
      i = s.indexOf('\n', i);
      if (i < 0) break;
    } else if (c == "'" || c == '"') {
      i = _endOfString(s, i);
    } else if (c == '(' || c == '[' || c == '{') {
      if (++depth == 1) addName(i);
    } else if (c == ')' || c == ']' || c == '}') {
      if (--depth == 0) return names;
    } else if (depth == 1 && c == ',') {
      addName(i);
    }
  }
  return names;
}

/// The index of the quote closing the string that opens at [start], skipping
/// escapes and `${...}` interpolations.
int _endOfString(String s, int start) {
  final quote = s[start];
  for (var i = start + 1; i < s.length; i++) {
    if (s[i] == r'\') {
      i++;
    } else if (s[i] == r'$' && s[i + 1] == '{') {
      var depth = 0;
      for (i = i + 1; i < s.length; i++) {
        if (s[i] == "'" || s[i] == '"') {
          i = _endOfString(s, i);
        } else if (s[i] == '{') {
          depth++;
        } else if (s[i] == '}' && --depth == 0) {
          break;
        }
      }
    } else if (s[i] == quote) {
      return i;
    }
  }
  return s.length;
}
