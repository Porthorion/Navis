import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

class SystemLibrarySyncNotifier {
  const new();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _silentChannelId = 'library_sync_silent';
  static const String _silentChannelName = 'Library Scan';
  static const String _silentChannelDescription =
      'Library scan progress and completion updates';
  static const int _progressId = 9101;
  static const int _summaryId = 9102;
  static const int _progressScale = 1000;
  static const Duration _throttleInterval = Duration(milliseconds: 500);

  static DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> showProgress(LibrarySyncState state) async {
    final now = DateTime.now();
    final elapsed = now.difference(_lastProgressUpdate);
    final total = state.total ?? 0;
    final processed = state.processed ?? 0;
    final isFinalProgressUpdate =
        total > 0 && processed >= total && !state.isHydrating;
    if (elapsed < _throttleInterval && !isFinalProgressUpdate) {
      return;
    }
    _lastProgressUpdate = now;

    final hasProgress = total > 0;
    final normProgress = hasProgress
        ? (processed * _progressScale ~/ total).clamp(0, _progressScale)
        : 0;
    await _safeShow(
      _progressId,
      title: 'Scanning library',
      body: _progressBody(state),
      details: _details(
        progress: true,
        determinate: hasProgress,
        value: normProgress,
      ),
    );
  }

  Future<void> dismissProgress() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _plugin.cancel(id: _progressId);
    } on Object {
      // Ignore in tests and unsupported environments.
    }
  }

  Future<void> showComplete(LibrarySyncState state) async {
    await dismissProgress();
    await _safeShow(
      _summaryId,
      title: 'Library scan complete',
      body: _completionBody(state),
      details: _details(progress: false),
    );
  }

  Future<void> showFailed(LibrarySyncState state) async {
    await dismissProgress();
    await _safeShow(
      _summaryId,
      title: librarySyncNotificationFailureTitle(state),
      body: librarySyncNotificationFailureBody(state),
      details: _details(progress: false),
    );
  }

  /// Silent low-priority details. [progress] makes the notification the
  /// ongoing scan-progress one; [determinate] adds a bar at [value] of 1000.
  static AndroidNotificationDetails _details({
    required bool progress,
    bool determinate = false,
    int value = 0,
  }) {
    return AndroidNotificationDetails(
      _silentChannelId,
      _silentChannelName,
      channelDescription: _silentChannelDescription,
      icon: 'ic_stat_navis_light',
      color: Colors.white,
      importance: Importance.low,
      priority: Priority.low,
      playSound: false,
      enableVibration: false,
      onlyAlertOnce: progress,
      ongoing: progress,
      autoCancel: !progress,
      showProgress: determinate,
      maxProgress: progress ? _progressScale : 0,
      progress: value,
      category: progress ? AndroidNotificationCategory.progress : null,
    );
  }

  Future<void> _safeShow(
    int id, {
    required String title,
    required String body,
    required AndroidNotificationDetails details,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(android: details),
      );
    } on Object {
      // Ignore in tests and unsupported environments.
    }
  }
}

String _progressBody(LibrarySyncState state) {
  final label = _stageLabel(state);
  final processed = state.processed;
  final total = state.total;
  if (processed != null && total != null && total > 0) {
    return '$label • $processed/$total';
  }
  return label;
}

String _completionBody(LibrarySyncState state) {
  final hydratedAlbums = state.hydratedAlbums ?? 0;
  final requestCount = state.apiRequests;
  if (hydratedAlbums > 0) {
    return 'Updated metadata and hydrated $hydratedAlbums albums.';
  }
  if (requestCount > 0) {
    return 'Metadata refresh finished successfully.';
  }
  return 'Library is already up to date.';
}

String librarySyncNotificationFailureTitle(LibrarySyncState state) {
  if (librarySyncNotificationWasCancelled(state)) {
    return 'Library scan cancelled';
  }
  return 'Library scan failed';
}

String librarySyncNotificationFailureBody(LibrarySyncState state) {
  // Sync state keeps raw transport and backend detail for diagnostics, but a
  // system notification is a recovery surface, not a log viewer. Preserve a
  // stable, safe next step instead of exposing server implementation detail.
  return librarySyncNotificationWasCancelled(state)
      ? 'The scan stopped before it finished. Open Navis to try again.'
      : 'The scan could not finish. Open Navis to try again.';
}

bool librarySyncNotificationWasCancelled(LibrarySyncState state) {
  return (state.errorMessage?.toLowerCase() ?? '').contains('cancel');
}

String _stageLabel(LibrarySyncState state) {
  return switch (state.stage) {
    LibrarySyncStage.preparing => 'Preparing scan',
    LibrarySyncStage.fetchingArtists => 'Refreshing artists',
    LibrarySyncStage.fetchingAlbums => 'Refreshing albums',
    LibrarySyncStage.persistingMetadata => 'Saving metadata',
    LibrarySyncStage.fetchingSongs => 'Hydrating songs',
    LibrarySyncStage.fetchingStarred => 'Updating liked items',
    LibrarySyncStage.fetchingPlaylists => 'Updating playlists',
    LibrarySyncStage.collectingCandidate => 'Building catalog update',
    LibrarySyncStage.validatingCandidate => 'Validating catalog update',
    LibrarySyncStage.applyingCandidate => 'Applying catalog update',
    LibrarySyncStage.cleaningCandidate => 'Cleaning up catalog update',
    LibrarySyncStage.finalizing => 'Finalizing scan',
    LibrarySyncStage.completed => 'Scan complete',
    LibrarySyncStage.idle => 'Waiting to scan',
  };
}
