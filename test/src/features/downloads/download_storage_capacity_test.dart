import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/downloads/data/download_storage_capacity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.navis.app/storage_capacity');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('queries the filesystem containing the destination directory', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'freeBytes');
      expect(call.arguments, {'path': '/fixture/downloads'});
      return 1024;
    });
    expect(await downloadStorageFreeBytes('/fixture/downloads'), 1024);
  });

  test('an unavailable native capacity report remains unknown', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await downloadStorageFreeBytes('/fixture/downloads'), isNull);
  });

  test('a failed native capacity report remains unknown', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'CAPACITY_UNAVAILABLE');
    });
    expect(await downloadStorageFreeBytes('/fixture/downloads'), isNull);
  });

  test('an unsupported channel remains unknown', () async {
    expect(await downloadStorageFreeBytes('/fixture/downloads'), isNull);
  });

  group('excludeFromBackup', () {
    test('asks the native side to exclude the path', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'excludeFromBackup');
        expect(call.arguments, {'path': '/fixture/downloads'});
        return true;
      });
      expect(await excludeFromBackup('/fixture/downloads'), isTrue);
    });

    test('a native failure or missing channel is ignored', () async {
      expect(await excludeFromBackup('/fixture/downloads'), isFalse);
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'EXCLUDE_FAILED');
      });
      expect(await excludeFromBackup('/fixture/downloads'), isFalse);
    });
  });

  group('BackupExclusion', () {
    final directory = Directory('/fixture/downloads');

    test('other platforms never call the native side', () async {
      final calls = <String>[];
      final exclusion = BackupExclusion(
        isIOS: false,
        exclude: (path) async {
          calls.add(path);
          return true;
        },
      );
      await exclusion.apply(directory, created: true);
      expect(calls, isEmpty);
    });

    test('iOS excludes on creation and once per process otherwise', () async {
      final calls = <String>[];
      final exclusion = BackupExclusion(
        isIOS: true,
        exclude: (path) async {
          calls.add(path);
          return true;
        },
      );
      await exclusion.apply(directory, created: false);
      await exclusion.apply(directory, created: false);
      expect(calls, [directory.path]);
      // Recreated after a clear-all: the attribute is gone, apply again.
      await exclusion.apply(directory, created: true);
      expect(calls, [directory.path, directory.path]);
      await exclusion.apply(Directory('/fixture/artwork'), created: false);
      expect(calls.length, 3);
    });

    test('a throwing exclusion never propagates', () async {
      final exclusion = BackupExclusion(
        isIOS: true,
        exclude: (_) async => throw StateError('boom'),
      );
      await exclusion.apply(directory, created: true);
    });
  });
}
