import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Manages download-progress and completion notifications on the
/// `downloads` Android notification channel.
class DownloadNotifier {
  DownloadNotifier._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Fixed notification ID used for the ongoing progress notification.
  static const int _progressId = 9001;

  /// Fixed notification ID used for the completion/failure summary.
  static const int _summaryId = 9002;

  /// Show or update a download-progress notification.
  static Future<void> showProgress({
    required String title,
    required int received,
    required int total,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;

    final androidDetails = AndroidNotificationDetails(
      'downloads',
      'Downloads',
      channelDescription: 'Download queue and progress updates',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: total,
      progress: received,
    );

    await _plugin.show(
      _progressId,
      title,
      null,
      NotificationDetails(android: androidDetails),
    );
  }

  /// Dismiss the ongoing progress notification.
  static Future<void> dismissProgress() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _plugin.cancel(_progressId);
  }

  /// Show a notification when a download completes successfully.
  static Future<void> showComplete({required String title}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;

    const androidDetails = AndroidNotificationDetails(
      'downloads',
      'Downloads',
      channelDescription: 'Download queue and progress updates',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );

    await _plugin.show(
      _summaryId,
      title,
      null,
      const NotificationDetails(android: androidDetails),
    );
  }

  /// Show a notification when a download fails.
  static Future<void> showFailed({required String title}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;

    const androidDetails = AndroidNotificationDetails(
      'downloads',
      'Downloads',
      channelDescription: 'Download queue and progress updates',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );

    await _plugin.show(
      _summaryId,
      title,
      null,
      const NotificationDetails(android: androidDetails),
    );
  }
}
