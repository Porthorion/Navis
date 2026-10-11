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
}
