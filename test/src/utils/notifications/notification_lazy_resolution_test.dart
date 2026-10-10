import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:navis/src/utils/notifications/download_notifier.dart';
import 'package:navis/src/utils/notifications/library_sync_notifier.dart';
import 'package:navis/src/utils/notifications/notification_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('download notifications do not resolve locale off Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await DownloadNotifier.showProgress(
      readLocalizations: () => throw StateError('locale read'),
      title: (_) => throw StateError('title read'),
      received: 1,
      total: 1,
    );
    await DownloadNotifier.showComplete(
      readLocalizations: () => throw StateError('locale read'),
      title: (_) => throw StateError('title read'),
    );
    await DownloadNotifier.showFailed(
      readLocalizations: () => throw StateError('locale read'),
    );
    expect(calls, isEmpty);
  });

  test('sync notifier resolves the current language through its callback', () {
    var locale = 'en';
    var reads = 0;
    final notifier = SystemLibrarySyncNotifier(
      readLocalizations: () {
        reads++;
        return resolveNotificationLocalizations(locale);
      },
    );
    expect(reads, 0);
    expect(notifier.readLocalizations().localeName, 'en');
    // English is currently the only shipped locale.
    locale = 'fr';
    expect(notifier.readLocalizations().localeName, 'en');
    expect(reads, 2);
  });
}
