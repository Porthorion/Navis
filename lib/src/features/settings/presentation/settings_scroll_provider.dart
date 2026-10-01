import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Incremented when the Settings tab is re-selected. `SettingsScreen`
/// scrolls its list back to the top when the value changes.
class _SettingsScrollToTopNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final settingsScrollToTopRequestProvider =
    NotifierProvider<_SettingsScrollToTopNotifier, int>(
      _SettingsScrollToTopNotifier.new,
    );
