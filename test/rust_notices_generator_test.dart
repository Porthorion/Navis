import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('rust-notices-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  const script =
      'import importlib.util, json, pathlib, sys; '
      'spec = importlib.util.spec_from_file_location("notices", sys.argv[1]); '
      'module = importlib.util.module_from_spec(spec); '
      'spec.loader.exec_module(module); '
      'crate = json.loads(sys.argv[4]); '
      'crate["manifest_path"] = str(pathlib.Path(sys.argv[2]) / "Cargo.toml"); '
      'print(json.dumps(module.crate_licence_texts(crate, pathlib.Path(sys.argv[3]))))';

  Future<ProcessResult> generate(Map<String, Object?> metadata) =>
      Process.run('python3', [
        '-B',
        '-c',
        script,
        File('tool/generate_rust_notices.py').absolute.path,
        root.path,
        Directory('tool/data/spdx').absolute.path,
        jsonEncode({'name': 'fixture', 'version': '1.0', ...metadata}),
      ]);

  test('licence files are matched without case sensitivity', () async {
    for (final name in [
      'license-mit',
      'license-apache-2.0',
      'LICENSE.md',
      'license.txt',
    ]) {
      await File(p.join(root.path, name))
          .writeAsString('fixture licence $name');
    }
    final result = await generate({'license': 'MIT'});
    expect(result.exitCode, 0, reason: result.stderr as String);
    final texts = jsonDecode(result.stdout as String) as List<dynamic>;
    expect(texts, hasLength(4));
    expect(
      texts.map((item) => (item as List<dynamic>).first),
      unorderedEquals([
        'license-mit',
        'license-apache-2.0',
        'LICENSE.md',
        'license.txt',
      ]),
    );
  });

  test(
    'missing files receive every licence in a compound SPDX expression',
    () async {
      final result = await generate({
        'license': '(MIT OR Apache-2.0) AND Unicode-3.0',
        'authors': ['Fixture contributors'],
      });
      expect(result.exitCode, 0, reason: result.stderr as String);
      final texts = jsonDecode(result.stdout as String) as List<dynamic>;
      expect(texts, hasLength(3));
      final full = result.stdout as String;
      expect(full, contains('Copyright (c) Fixture contributors'));
      expect(
        full,
        contains(
          'TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION',
        ),
      );
      expect(full, contains('UNICODE LICENSE V3'));
    },
  );

  test(
    'MIT fallback attributes missing authors to the crate authors',
    () async {
      final result = await generate({'license': 'MIT', 'authors': <String>[]});
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        result.stdout as String,
        contains('Copyright (c) the fixture authors'),
      );
    },
  );

  test('unknown SPDX fallback fails instead of inventing a notice', () async {
    final result = await generate({'license': 'LicenseRef-Unknown'});
    expect(result.exitCode, isNot(0));
    expect(result.stderr as String, contains('unsupported SPDX fallback'));
  });
}
