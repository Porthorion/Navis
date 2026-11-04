import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/bootstrap/file_picker_bootstrap.dart';

void main() {
  late FilePickerPlatform previous;

  setUp(() {
    previous = FilePickerPlatform.instance;
  });

  tearDown(() {
    FilePickerPlatform.instance = previous;
  });

  test('skips the macOS entitlement checks once', () async {
    final picker = _FakeFilePicker();
    FilePickerPlatform.instance = picker;

    await configureFilePicker();

    expect(picker.skipEntitlementsCalls, 1);
    expect(picker.directoryCalls, 0);
  });

  test('a failing platform never blocks startup', () async {
    FilePickerPlatform.instance = _FakeFilePicker(
      error: PlatformException(code: 'ENTITLEMENT_NOT_FOUND'),
    );

    await expectLater(configureFilePicker(), completes);
  });
}

class _FakeFilePicker extends FilePickerPlatform {
  _FakeFilePicker({this.error});

  final Exception? error;
  int skipEntitlementsCalls = 0;
  int directoryCalls = 0;

  @override
  Future<void> skipEntitlementsChecks() async {
    skipEntitlementsCalls++;
    final failure = error;
    if (failure != null) throw failure;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    directoryCalls++;
    return null;
  }
}
