import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

abstract class LibrarySyncNotifier {
  const LibrarySyncNotifier();

  Future<void> showProgress(LibrarySyncState state);
  Future<void> dismissProgress();
  Future<void> showComplete(LibrarySyncState state);
  Future<void> showFailed(LibrarySyncState state);
}

class SystemLibrarySyncNotifier implements LibrarySyncNotifier {
  const SystemLibrarySyncNotifier();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const int _progressId = 9101;
  static const int _summaryId = 9102;
  static const Duration _throttleInterval = Duration(milliseconds: 500);

  static DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<void> showProgress(LibrarySyncState state) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

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
    const normMax = 1000;
    final normProgress = hasProgress
        ? (processed * normMax ~/ total).clamp(0, normMax)
        : 0;
    final androidDetails = AndroidNotificationDetails(
      'library_sync',
      'Library Scan',
      channelDescription: 'Library scan progress and completion updates',
      icon: 'ic_stat_navis_light',
      color: const Color(0xFFFFFFFF),
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      showProgress: hasProgress,
      maxProgress: normMax,
      progress: normProgress,
      category: AndroidNotificationCategory.progress,
    );

    await _safeShow(
      _progressId,
      title: 'Scanning library',
      body: _progressBody(state),
      details: androidDetails,
    );
  }

  @override
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

  @override
  Future<void> showComplete(LibrarySyncState state) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await dismissProgress();
    const androidDetails = AndroidNotificationDetails(
      'library_sync',
      'Library Scan',
      channelDescription: 'Library scan progress and completion updates',
      icon: 'ic_stat_navis_light',
      color: Color(0xFFFFFFFF),
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    await _safeShow(
      _summaryId,
      title: 'Library scan complete',
      body: _completionBody(state),
      details: androidDetails,
    );
  }

  @override
  Future<void> showFailed(LibrarySyncState state) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await dismissProgress();
    const androidDetails = AndroidNotificationDetails(
      'library_sync',
      'Library Scan',
      channelDescription: 'Library scan progress and completion updates',
      icon: 'ic_stat_navis_light',
      color: Color(0xFFFFFFFF),
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    await _safeShow(
      _summaryId,
      title: _failureTitle(state),
      body: _failureBody(state),
      details: androidDetails,
    );
  }

  Future<void> _safeShow(
    int id, {
    required String title,
    required String body,
    required AndroidNotificationDetails details,
  }) async {
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

String _failureTitle(LibrarySyncState state) {
  final message = state.errorMessage?.toLowerCase() ?? '';
  if (message.contains('cancel')) {
    return 'Library scan cancelled';
  }
  return 'Library scan failed';
}

String _failureBody(LibrarySyncState state) {
  final message = state.errorMessage?.trim();
  if (message != null && message.isNotEmpty) {
    return message;
  }
  return 'Something interrupted the scan.';
}

String _stageLabel(LibrarySyncState state) {
  return switch (state.stage) {
    LibrarySyncStage.preparing => 'Preparing scan',
    LibrarySyncStage.fetchingArtists => 'Refreshing artists',
    LibrarySyncStage.fetchingAlbums => 'Refreshing albums',
    LibrarySyncStage.persistingMetadata => 'Saving metadata',
    LibrarySyncStage.fetchingSongs => 'Hydrating songs',
    LibrarySyncStage.fetchingGenres => 'Refreshing genres',
    LibrarySyncStage.fetchingPlaylists => 'Refreshing playlists',
    LibrarySyncStage.finalizing => 'Finalizing scan',
    LibrarySyncStage.completed => 'Scan complete',
    LibrarySyncStage.idle => 'Waiting to scan',
  };
}
