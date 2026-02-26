import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Incremented whenever the user taps the Home nav icon while already on
/// the Home screen. `HomeScreen` watches this provider and scrolls the
/// content back to the top when the value changes.
class _HomeScrollToTopNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final homeScrollToTopRequestProvider =
    NotifierProvider<_HomeScrollToTopNotifier, int>(
      _HomeScrollToTopNotifier.new,
    );
