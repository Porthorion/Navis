import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Counts live provider elements for the diagnostics report.
///
/// Only installed on the root container when the sync diagnostics runtime is
/// enabled. Family members are grouped by their family's description (type
/// and identity hash), so an unbounded family shows up as one large bucket
/// without exposing any family argument such as a song or album ID.
final class DiagnosticsProviderCounter extends ProviderObserver {
  int _alive = 0;
  int _added = 0;
  int _disposed = 0;
  final Map<String, int> _aliveByFamily = <String, int>{};

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    _alive++;
    _added++;
    final family = context.provider.from;
    if (family != null) {
      final key = family.toString();
      _aliveByFamily[key] = (_aliveByFamily[key] ?? 0) + 1;
    }
  }

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    _alive--;
    _disposed++;
    final family = context.provider.from;
    if (family != null) {
      final key = family.toString();
      final remaining = (_aliveByFamily[key] ?? 0) - 1;
      if (remaining <= 0) {
        _aliveByFamily.remove(key);
      } else {
        _aliveByFamily[key] = remaining;
      }
    }
  }

  Map<String, Object?> toJson({int topFamilies = 10}) {
    final families = _aliveByFamily.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return <String, Object?>{
      'alive': _alive,
      'added': _added,
      'disposed': _disposed,
      'familyInstances': _aliveByFamily.values.fold<int>(0, (a, b) => a + b),
      'largestFamilies': <Map<String, Object?>>[
        for (final entry in families.take(topFamilies))
          <String, Object?>{'family': entry.key, 'alive': entry.value},
      ],
    };
  }
}
