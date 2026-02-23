import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Controls the expanded/collapsed state of the Now Playing sheet overlay.
class PlayerSheetController extends Notifier<bool> {
  @override
  bool build() => false;

  void expand() => state = true;

  void collapse() => state = false;

  void toggle() => state = !state;
}

final playerSheetExpandedProvider =
    NotifierProvider<PlayerSheetController, bool>(
  PlayerSheetController.new,
);
