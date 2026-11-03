import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Runs for every test file. Visibility callbacks fire without the plugin's
/// 500 ms debounce timer, which would otherwise leave a pending timer behind
/// whenever a widget test builds a [VisibilityDetector] (for example a
/// scrolling album title).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  if (Platform.isMacOS) {
    // flutter_cache_manager stores its index in sqflite on macOS (JSON on
    // Linux); the test host has no sqflite plugin, so use the FFI factory.
    databaseFactory = databaseFactoryFfi;
    // TMPDIR sits behind /var -> /private/var; production code resolves real
    // paths, so hand tests the canonical temp directory.
    IOOverrides.global = _CanonicalSystemTemp(
      Directory(Directory.systemTemp.resolveSymbolicLinksSync()),
    );
  }
  if (!Platform.isLinux) {
    // Goldens are rendered on Linux; Linux CI and check.sh stay authoritative.
    goldenFileComparator = _SkippingGoldenComparator(goldenFileComparator);
  }
  await testMain();
}

final class _CanonicalSystemTemp extends IOOverrides {
  new(this._temp);

  final Directory _temp;

  @override
  Directory getSystemTempDirectory() => _temp;
}

class _SkippingGoldenComparator extends GoldenFileComparator {
  new(this._inner);

  final GoldenFileComparator _inner;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  // Never overwrite the Linux-rendered goldens from another host.
  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}

  @override
  Uri getTestUri(Uri key, int? version) => _inner.getTestUri(key, version);
}
