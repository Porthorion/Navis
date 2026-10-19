import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations_en.dart';
import 'package:navis/src/utils/notifications/notification_bootstrap.dart';

class _Translated extends AppLocalizationsEn {
  @override
  String get notificationPlaybackChannelName => 'Lecture';
  @override
  String get notificationPlaybackChannelDescription => 'Lecture desc';
  @override
  String get notificationDownloadsChannelName => 'Telechargements';
  @override
  String get notificationDownloadsChannelDescription => 'Telechargements desc';
  @override
  String get notificationLibraryScanChannelName => 'Analyse';
  @override
  String get notificationLibraryScanChannelDescription => 'Analyse desc';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'createNotificationChannel' ? null : true;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  Map<String, Map<dynamic, dynamic>> channels() => {
    for (final c in calls.where((c) => c.method == 'createNotificationChannel'))
      (c.arguments as Map)['id'] as String: c.arguments as Map,
  };

  test('channel names and descriptions come from localizations', () async {
    await NotificationBootstrap.initialize(readLocalizations: _Translated.new);
    final created = channels();
    expect(created.keys, {'playback', 'downloads', 'library_sync_silent'});
    expect(created['playback']!['name'], 'Lecture');
    expect(created['playback']!['description'], 'Lecture desc');
    expect(created['downloads']!['name'], 'Telechargements');
    expect(created['downloads']!['description'], 'Telechargements desc');
    expect(created['library_sync_silent']!['name'], 'Analyse');
    expect(created['library_sync_silent']!['description'], 'Analyse desc');
  });

  test('locale is not read off Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await NotificationBootstrap.initialize(
      readLocalizations: () => throw StateError('locale read'),
    );
    expect(calls, isEmpty);
  });
}
