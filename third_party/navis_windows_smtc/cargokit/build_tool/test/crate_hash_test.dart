import 'dart:io';

import 'package:build_tool/src/crate_hash.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory crate;

  setUp(() {
    root = Directory.systemTemp.createTempSync('navis-crate-hash-');
    crate = Directory(path.join(root.path, 'rust'))..createSync();
    final src = Directory(path.join(crate.path, 'src'))..createSync();
    File(path.join(src.path, 'lib.rs')).writeAsStringSync('pub fn run() {}');
    File(
      path.join(crate.path, 'Cargo.toml'),
    ).writeAsStringSync('[package]\nname = "fixture"\nversion = "0.1.0"\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('workspace lock updates invalidate cached artifact hashes', () {
    File(
      path.join(root.path, 'Cargo.toml'),
    ).writeAsStringSync('[workspace]\nmembers = ["rust"]\n');
    final lock = File(path.join(root.path, 'Cargo.lock'));
    lock.writeAsStringSync('version = 3\n# old dependency graph\n');
    final before = CrateHash.compute(crate.path, tempStorage: root.path);
    lock.writeAsStringSync(
      'version = 4\n# patched dependency graph changes size\n',
    );
    expect(
      CrateHash.compute(crate.path, tempStorage: root.path),
      isNot(before),
    );
  });

  test('workspace manifest updates invalidate artifact hashes', () {
    final manifest = File(path.join(root.path, 'Cargo.toml'));
    manifest.writeAsStringSync('[workspace]\nmembers = ["rust"]\n');
    final before = CrateHash.compute(crate.path);
    manifest.writeAsStringSync(
      '[workspace]\nmembers = ["rust"]\n[profile.release]\nlto = true\n',
    );
    expect(CrateHash.compute(crate.path), isNot(before));
  });

  test('stale member lock does not override workspace lock', () {
    File(
      path.join(root.path, 'Cargo.toml'),
    ).writeAsStringSync('[workspace]\nmembers = ["rust"]\n');
    File(path.join(root.path, 'Cargo.lock')).writeAsStringSync('version = 4\n');
    final before = CrateHash.compute(crate.path);
    File(
      path.join(crate.path, 'Cargo.lock'),
    ).writeAsStringSync('stale member lock');
    expect(CrateHash.compute(crate.path), before);
  });

  test('standalone crate still hashes its own lock', () {
    final lock = File(path.join(crate.path, 'Cargo.lock'));
    lock.writeAsStringSync('original dependency graph');
    final before = CrateHash.compute(crate.path);
    lock.writeAsStringSync('updated dependency graph');
    expect(CrateHash.compute(crate.path), isNot(before));
  });
}
