import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/update_scripts.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workDir;

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp('navis_script_test_');
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['700', workDir.path]);
      expect(result.exitCode, 0);
    }
  });

  tearDown(() async {
    await workDir.delete(recursive: true);
  });

  for (final isMacos in [false, true]) {
    test(
      'Unix script and staging paths stay in private work dir (macOS: $isMacos)',
      () async {
        final staging = p.join(workDir.path, 'staging');
        final scriptPath = await UpdateScripts.writeUnixScript(
          workDir: workDir.path,
          targetPath: '/opt/Navis',
          stagingPath: staging,
          isMacos: isMacos,
          relaunchCommand: '/opt/Navis/navis',
        );
        final script = File(scriptPath);
        expect(p.dirname(scriptPath), workDir.path);
        expect(
          await script.readAsString(),
          contains("mv '$staging' '/opt/Navis'"),
        );
        expect(script.statSync().mode & 0x1ff, 0x1c0);
      },
      skip: Platform.isWindows,
    );
  }
}
