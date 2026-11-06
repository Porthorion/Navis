import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/diagnostics_build_gate.dart';

void main() {
  const simulator =
      '/Users/me/Library/Developer/CoreSimulator/Devices/ABC/data/Containers/'
      'Bundle/Application/DEF/Runner.app/Runner';
  const device =
      '/private/var/containers/Bundle/Application/DEF/Runner.app/Runner';

  bool allowed({
    bool profile = false,
    bool debug = false,
    bool ios = false,
    String executablePath = device,
  }) => diagnosticsBuildAllowed(
    profileMode: profile,
    debugMode: debug,
    isIOS: ios,
    executablePath: executablePath,
  );

  test('profile builds are on everywhere', () {
    expect(allowed(profile: true), isTrue);
    expect(allowed(profile: true, ios: true), isTrue);
    expect(
      allowed(profile: true, ios: true, executablePath: simulator),
      isTrue,
    );
  });

  test('debug builds are on only in the iOS simulator', () {
    expect(allowed(debug: true, ios: true, executablePath: simulator), isTrue);
    expect(allowed(debug: true, ios: true), isFalse, reason: 'physical device');
    expect(
      allowed(debug: true, executablePath: simulator),
      isFalse,
      reason: 'a non-iOS host that merely runs from such a path',
    );
    expect(allowed(debug: true), isFalse, reason: 'macOS, Linux, Android');
  });

  test('release builds are off everywhere', () {
    expect(allowed(), isFalse);
    expect(allowed(ios: true, executablePath: simulator), isFalse);
  });

  test('the host test runner (debug, not iOS) is off', () {
    expect(diagnosticsBuildEnabled, isFalse);
  });
}
