import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/bootstrap/bundled_libmpv.dart';

void main() {
  test('Linux uses the library beside the resolved executable', () {
    String? checked;
    expect(
      bundledLibmpvPath(
        isLinux: true,
        executable: '/opt/Navis bundle/navis',
        fileExists: (path) {
          checked = path;
          return true;
        },
      ),
      '/opt/Navis bundle/lib/libmpv.so.2',
    );
    expect(checked, '/opt/Navis bundle/lib/libmpv.so.2');
  });

  test('Linux falls back to system lookup when the bundle is absent', () {
    expect(
      bundledLibmpvPath(
        isLinux: true,
        executable: '/dev/navis',
        fileExists: (_) => false,
      ),
      isNull,
    );
  });

  test('other platforms never inspect or override their audio library', () {
    expect(
      bundledLibmpvPath(
        isLinux: false,
        fileExists: (_) => throw StateError('Must not inspect a Linux path'),
      ),
      isNull,
    );
  });
}
