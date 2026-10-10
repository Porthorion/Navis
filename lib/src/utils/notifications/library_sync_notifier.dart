import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/notifications/notification_localizations.dart';

class SystemLibrarySyncNotifier {
  const new({this.readLocalizations = _defaultLocalizations});

  /// Resolves the strings at notification time so a language change applies.
  final AppLocalizations Function() readLocalizations;

  static AppLocalizations _defaultLocalizations() =>
      resolveNotificationLocalizations(null);

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _silentChannelId = 'library_sync_silent';
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

    final l10n = readLocalizations();
    final hasProgress = total > 0;
    final normProgress = hasProgress
        ? (processed * _progressScale ~/ total).clamp(0, _progressScale)
        : 0;
    await _safeShow(
      _progressId,
      title: l10n.notificationLibraryScanProgressTitle,
      body: _progressBody(l10n, state),
      details: _details(
        l10n,
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
    final l10n = readLocalizations();
    await _safeShow(
      _summaryId,
      title: l10n.notificationLibraryScanCompleteTitle,
      body: _completionBody(l10n, state),
      details: _details(l10n, progress: false),
    );
  }

  Future<void> showFailed(LibrarySyncState state) async {
    await dismissProgress();
    final l10n = readLocalizations();
    await _safeShow(
      _summaryId,
      title: librarySyncNotificationFailureTitle(l10n, state),
      body: librarySyncNotificationFailureBody(l10n, state),
      details: _details(l10n, progress: false),
    );
  }

  /// Silent low-priority details. [progress] makes the notification the
  /// ongoing scan-progress one; [determinate] adds a bar at [value] of 1000.
  static AndroidNotificationDetails _details(
    AppLocalizations l10n, {
    required bool progress,
    bool determinate = false,
    int value = 0,
  }) {
    return AndroidNotificationDetails(
      _silentChannelId,
      l10n.notificationLibraryScanChannelName,
      channelDescription: l10n.notificationLibraryScanChannelDescription,
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

String _progressBody(AppLocalizations l10n, LibrarySyncState state) {
  final label = _stageLabel(l10n, state);
  final processed = state.processed;
  final total = state.total;
  if (processed != null && total != null && total > 0) {
    return l10n.notificationLibraryScanProgressBody(label, processed, total);
  }
  return label;
}

String _completionBody(AppLocalizations l10n, LibrarySyncState state) {
  final hydratedAlbums = state.hydratedAlbums ?? 0;
  final requestCount = state.apiRequests;
  if (hydratedAlbums > 0) {
    return l10n.notificationLibraryScanCompleteHydrated(hydratedAlbums);
  }
  if (requestCount > 0) {
    return l10n.notificationLibraryScanCompleteRefreshed;
  }
  return l10n.notificationLibraryScanCompleteUpToDate;
}

String librarySyncNotificationFailureTitle(
  AppLocalizations l10n,
  LibrarySyncState state,
) {
  if (librarySyncNotificationWasCancelled(state)) {
    return l10n.notificationLibraryScanCancelledTitle;
  }
  return l10n.notificationLibraryScanFailedTitle;
}

String librarySyncNotificationFailureBody(
  AppLocalizations l10n,
  LibrarySyncState state,
) {
  // Sync state keeps raw transport and backend detail for diagnostics, but a
  // system notification is a recovery surface, not a log viewer. Preserve a
  // stable, safe next step instead of exposing server implementation detail.
  return librarySyncNotificationWasCancelled(state)
      ? l10n.notificationLibraryScanCancelledBody
      : l10n.notificationLibraryScanFailedBody;
}

bool librarySyncNotificationWasCancelled(LibrarySyncState state) {
  return (state.errorMessage?.toLowerCase() ?? '').contains('cancel');
}

String _stageLabel(AppLocalizations l10n, LibrarySyncState state) {
  return switch (state.stage) {
    LibrarySyncStage.preparing => l10n.notificationLibraryScanStagePreparing,
    LibrarySyncStage.fetchingArtists =>
      l10n.notificationLibraryScanStageFetchingArtists,
    LibrarySyncStage.fetchingAlbums =>
      l10n.notificationLibraryScanStageFetchingAlbums,
    LibrarySyncStage.persistingMetadata =>
      l10n.notificationLibraryScanStagePersistingMetadata,
    LibrarySyncStage.fetchingSongs =>
      l10n.notificationLibraryScanStageFetchingSongs,
    LibrarySyncStage.fetchingStarred =>
      l10n.notificationLibraryScanStageFetchingStarred,
    LibrarySyncStage.fetchingPlaylists =>
      l10n.notificationLibraryScanStageFetchingPlaylists,
    LibrarySyncStage.collectingCandidate =>
      l10n.notificationLibraryScanStageCollectingCandidate,
    LibrarySyncStage.validatingCandidate =>
      l10n.notificationLibraryScanStageValidatingCandidate,
    LibrarySyncStage.applyingCandidate =>
      l10n.notificationLibraryScanStageApplyingCandidate,
    LibrarySyncStage.cleaningCandidate =>
      l10n.notificationLibraryScanStageCleaningCandidate,
    LibrarySyncStage.finalizing => l10n.notificationLibraryScanStageFinalizing,
    LibrarySyncStage.completed => l10n.notificationLibraryScanStageCompleted,
    LibrarySyncStage.idle => l10n.notificationLibraryScanStageIdle,
  };
}
