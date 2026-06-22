import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Explicit user gestures that may publish playback upstream.
enum UserPlaybackIntent {
  play,
  pause,
  seek,
  trackChange,
  queueAdd,
  queueRemove,
  queueReplace,
}

final groupListeningUserIntentProvider =
    NotifierProvider<GroupListeningUserIntentNotifier, int>(
      GroupListeningUserIntentNotifier.new,
    );

class GroupListeningUserIntentNotifier extends Notifier<int> {
  UserPlaybackIntent? _pendingIntent;
  DateTime? _recordedAt;

  @override
  int build() => 0;

  void record(UserPlaybackIntent intent) {
    _pendingIntent = intent;
    _recordedAt = DateTime.now();
    state++;
  }

  UserPlaybackIntent? peekIntent() => _pendingIntent;

  DateTime? peekRecordedAt() => _recordedAt;

  UserPlaybackIntent? consumeIntent() {
    final intent = _pendingIntent;
    _pendingIntent = null;
    _recordedAt = null;
    return intent;
  }

  bool hasRecentIntent({Duration window = const Duration(seconds: 3)}) {
    final recordedAt = _recordedAt;
    if (recordedAt == null) {
      return false;
    }
    return DateTime.now().difference(recordedAt) <= window;
  }
}
