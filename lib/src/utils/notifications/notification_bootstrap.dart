import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/notifications/notification_localizations.dart';

/// Handles notification channel setup and runtime permission requests.
class NotificationBootstrap {
  new _();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Initializes local notifications and creates required Android channels.
  ///
  /// Channel names come from [readLocalizations] (the in-app language override
  /// when set, else the platform language), read only on Android.
  static Future<void> initialize({
    AppLocalizations Function()? readLocalizations,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      if (kDebugMode) {
        AppLogger.info('Notification bootstrap skipped on non-Android target.');
      }
      return;
    }
    try {
      const androidInitSettings = AndroidInitializationSettings(
        'ic_stat_navis_light',
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

      final l10n =
          (readLocalizations ?? () => resolveNotificationLocalizations(null))();
      final playbackChannel = AndroidNotificationChannel(
        'playback',
        l10n.notificationPlaybackChannelName,
        description: l10n.notificationPlaybackChannelDescription,
        importance: Importance.low,
      );

      final downloadsChannel = AndroidNotificationChannel(
        'downloads',
        l10n.notificationDownloadsChannelName,
        description: l10n.notificationDownloadsChannelDescription,
      );

      final librarySyncChannel = AndroidNotificationChannel(
        'library_sync_silent',
        l10n.notificationLibraryScanChannelName,
        description: l10n.notificationLibraryScanChannelDescription,
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
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
    } on Object catch (error, stackTrace) {
      // Startup must not be blocked by notification setup failures.
      AppLogger.error(
        'Notification bootstrap failed. Continuing app startup without notifications.',
        error,
        stackTrace,
      );
    }
  }
}
