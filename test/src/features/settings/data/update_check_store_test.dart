import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;
  late UpdateCheckStore store;
  final now = DateTime.utc(2026, 10, 10, 12);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('navis_update_check_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => temp.path);
    store = UpdateCheckStore(now: () => now);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });

  test('writers merge keys and preserve timing across a new store', () async {
    final file = File(p.join(temp.path, 'update_check_state.json'));
    await file.writeAsString(jsonEncode({'futureKey': true}));
    expect(await store.readLastCheckAt(), isNull);
    expect(await store.readNotifiedVersion(), isNull);
    expect(await store.shouldCheck(), isTrue);
    await store.recordCheck();
    await store.recordNotifiedVersion('1.5.0+43');
    expect(await store.readLastCheckAt(), now);
    expect(await store.shouldCheck(), isFalse);
    expect(await store.shouldCheck(force: true), isTrue);
    final later = now.add(const Duration(hours: 1));
    await store.recordCheck(later);
    final reopened = UpdateCheckStore();
    expect(await reopened.readNotifiedVersion(), '1.5.0+43');
    expect(await reopened.readLastCheckAt(), later);
    await reopened.recordNotifiedVersion('1.5.0+44');
    expect(await reopened.readLastCheckAt(), later);
    expect(jsonDecode(await file.readAsString())['futureKey'], isTrue);
  });

  test('automatic throttle allows a new check after one hour', () async {
    var clock = now;
    final throttled = UpdateCheckStore(now: () => clock);
    await throttled.recordCheck();
    expect(await throttled.shouldCheck(), isFalse);
    clock = now.add(const Duration(hours: 1) - const Duration(seconds: 1));
    expect(await throttled.shouldCheck(), isFalse);
    clock = now.add(const Duration(hours: 1));
    expect(await throttled.shouldCheck(), isTrue);
  });

  test(
    'signed manifest round-trips and clears without losing dismissal',
    () async {
      const update = <String, Object?>{
        'payload': 'cGF5bG9hZA==',
        'signature': 'c2lnbmF0dXJl',
      };
      await store.recordDismissedUpdate('v1.5.1+43');
      await store.recordVerifiedManifest(update);
      expect(await store.readVerifiedManifest(), update);
      final reopened = UpdateCheckStore();
      expect(await reopened.readVerifiedManifest(), update);
      expect(await reopened.readLastCheckAt(), isNull);
      await reopened.clearVerifiedManifest();
      expect(await reopened.readVerifiedManifest(), isNull);
      expect(await reopened.readDismissedUpdate(), 'v1.5.1+43');
      // The other keys survive the clear.
      expect(
        jsonDecode(
          await File(p.join(temp.path, 'update_check_state.json'))
              .readAsString(),
        ),
        isNot(contains('verifiedManifest')),
      );
    },
  );

  test('concurrent writers retain all keys', () async {
    await Future.wait([
      store.recordCheck(),
      store.recordNotifiedVersion('1.5.0+43'),
      store.recordDismissedUpdate('v1.5.1+43'),
      store.recordVerifiedManifest({'payload': 'abc', 'signature': 'def'}),
    ]);
    expect(await store.readLastCheckAt(), now);
    expect(await store.readNotifiedVersion(), '1.5.0+43');
    final reopened = UpdateCheckStore();
    expect(await reopened.readDismissedUpdate(), 'v1.5.1+43');
    expect(await reopened.readVerifiedManifest(), {
      'payload': 'abc',
      'signature': 'def',
    });
  });

  for (final corrupt in [
    'not json',
    '[]',
    'null',
    '{"lastCheckAt":false,"notifiedVersion":42}',
    '{"verifiedManifest":"not-a-map"}',
    '{"dismissedUpdate":42}',
  ]) {
    for (final noticeFirst in [false, true]) {
      test(
        'corrupt state tolerates both writers: $corrupt, noticeFirst=$noticeFirst',
        () async {
          final file = File(p.join(temp.path, 'update_check_state.json'));
          await file.writeAsString(corrupt);
          expect(await store.readLastCheckAt(), isNull);
          expect(await store.readNotifiedVersion(), isNull);
          expect(await store.readVerifiedManifest(), isNull);
          expect(await store.readDismissedUpdate(), isNull);
          if (noticeFirst) {
            await store.recordNotifiedVersion('1.5.0+43');
            await store.recordCheck();
          } else {
            await store.recordCheck();
            await store.recordNotifiedVersion('1.5.0+43');
          }
          expect(await store.readLastCheckAt(), now);
          expect(await store.readNotifiedVersion(), '1.5.0+43');
        },
      );
    }
  }
}
