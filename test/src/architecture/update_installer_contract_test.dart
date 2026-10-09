import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'only the silent installer relaunch explicitly uses the original user',
    () {
      final source = File('tool/windows/build_inno_installer.ps1')
          .readAsStringSync();
      final runEntries = source
          .split('\n')
          .where((line) => line.startsWith('Filename:'));
      final silent = runEntries.singleWhere(
        (line) => line.contains('skipifnotsilent'),
      );
      expect(silent, contains('runasoriginaluser'));
      final interactive = runEntries.singleWhere(
        (line) => line.contains('postinstall'),
      );
      expect(interactive, contains('nowait postinstall skipifsilent'));
      expect(interactive, isNot(contains('runasoriginaluser')));
    },
  );
}
