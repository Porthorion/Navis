import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Manages download-progress and completion notifications on the
/// `downloads` Android notification channel.
class DownloadNotifier {
  new _();

  /// Notification titles must not include internal song IDs or backend detail.
  static const String failureNotificationTitle = 'Download failed';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Fixed notification ID used for the ongoing progress notification.
  static const int _progressId = 9001;

  /// Fixed notification ID used for the completion/failure summary.
  static const int _summaryId = 9002;

  /// Throttle: minimum interval between progress updates.
  static const Duration _throttleInterval = Duration(milliseconds: 500);

  /// Tracks the last time a progress notification was actually displayed.
  static DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  /// Show or update a download-progress notification.
  ///
  /// Throttled to avoid flooding the notification system with updates.
  static Future<void> showProgress({
    required String title,
    required int received,
    required int total,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;

    // Throttle updates to avoid overwhelming the notification system.
    final now = DateTime.now();
    final elapsed = now.difference(_lastProgressUpdate);
    // Always show the final update (received >= total).
    if (elapsed < _throttleInterval && received < total) return;
    _lastProgressUpdate = now;

    // Normalise to 0-1000 range to avoid int overflow with large files.
    const normMax = 1000;
    final normProgress = total > 0
        ? (received * normMax ~/ total).clamp(0, normMax)
        : 0;

    final androidDetails = AndroidNotificationDetails(
      'downloads',
      'Downloads',
      channelDescription: 'Download queue and progress updates',
      icon: 'ic_stat_navis_light',
      color: Colors.white,
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: normMax,
      progress: normProgress,
    );

    try {
      await _plugin.show(
        id: _progressId,
        title: title,
        body: '${received * 100 ~/ (total > 0 ? total : 1)}%',
        notificationDetails: NotificationDetails(android: androidDetails),
      );
    } on Object {
      // Notifications are best-effort in tests and unsupported environments.
    }
  }

  /// Dismiss the ongoing progress notification.
  static Future<void> dismissProgress() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _plugin.cancel(id: _progressId);
    } on Object {
      // Notifications are best-effort in tests and unsupported environments.
    }
  }

  /// Show a notification when a download completes successfully.
  static Future<void> showComplete({required String title}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;

    const androidDetails = AndroidNotificationDetails(
      'downloads',
      'Downloads',
      channelDescription: 'Download queue and progress updates',
      icon: 'ic_stat_navis_light',
      color: Colors.white,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );

    try {
      await _plugin.show(
        id: _summaryId,
        title: title,
        notificationDetails: const NotificationDetails(android: androidDetails),
      );
    } on Object {
      // Notifications are best-effort in tests and unsupported environments.
    }
  }

  /// Show a notification when a download fails.
  static Future<void> showFailed() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;

    const androidDetails = AndroidNotificationDetails(
      'downloads',
      'Downloads',
      channelDescription: 'Download queue and progress updates',
      icon: 'ic_stat_navis_light',
      color: Colors.white,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );

    try {
      await _plugin.show(
        id: _summaryId,
        title: failureNotificationTitle,
        notificationDetails: const NotificationDetails(android: androidDetails),
      );
    } on Object {
      // Notifications are best-effort in tests and unsupported environments.
    }
  }
}
