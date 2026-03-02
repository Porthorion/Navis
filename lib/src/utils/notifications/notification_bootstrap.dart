import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Handles notification channel setup and runtime permission requests.
class NotificationBootstrap {
  NotificationBootstrap._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Initializes local notifications and creates required Android channels.
  static Future<void> initialize() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      if (kDebugMode) {
        AppLogger.info('Notification bootstrap skipped on non-Android target.');
      }
      return;
    }

    const androidInitSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidInitSettings);

    await _plugin.initialize(settings: initSettings);

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    if (androidPlugin == null) {
      return;
    }

    const playbackChannel = AndroidNotificationChannel(
      'playback',
      'Playback',
      description: 'Media playback controls and status',
      importance: Importance.low,
    );

    const downloadsChannel = AndroidNotificationChannel(
      'downloads',
      'Downloads',
      description: 'Download queue and progress updates',
    );

    const librarySyncChannel = AndroidNotificationChannel(
      'library_sync',
      'Library Scan',
      description: 'Library scan progress and completion updates',
    );

    await androidPlugin.createNotificationChannel(playbackChannel);
    await androidPlugin.createNotificationChannel(downloadsChannel);
    await androidPlugin.createNotificationChannel(librarySyncChannel);

    final granted = await androidPlugin.requestNotificationsPermission();
    if (granted == false) {
      AppLogger.warning(
        'Android notification permission denied. Notifications are disabled.',
      );
    } else {
      AppLogger.info('Android notification channels initialized.');
    }

    if (kDebugMode) {
      AppLogger.info('Notification bootstrap completed.');
    }
  }
}
