import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/downloads/data/download_directory_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.navis.app/directory_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('macOS uses the native panel that can create folders', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pick');
      expect(call.arguments, {'title': 'Choose'});
      return '/Users/me/Music/New Folder';
    });
    expect(
      await pickDownloadDirectory(title: 'Choose', useNativeMacPanel: true),
      '/Users/me/Music/New Folder',
    );
  });

  test('a cancelled native panel picks nothing', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(
      await pickDownloadDirectory(title: 'Choose', useNativeMacPanel: true),
      isNull,
    );
  });

  test('a failed native panel falls back to file_picker', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'PANEL_FAILED');
    });
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakePicker('/fallback');
    addTearDown(() => FilePickerPlatform.instance = previous);
    expect(
      await pickDownloadDirectory(title: 'Choose', useNativeMacPanel: true),
      '/fallback',
    );
  });

  test('a Runner without the channel falls back to file_picker', () async {
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakePicker('/fallback');
    addTearDown(() => FilePickerPlatform.instance = previous);
    expect(
      await pickDownloadDirectory(title: 'Choose', useNativeMacPanel: true),
      '/fallback',
    );
  });
}

class _FakePicker extends FilePickerPlatform {
  new(this.path);
  final String? path;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => path;
}
