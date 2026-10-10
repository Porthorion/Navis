import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Matches Android's application ID check without waiting for MainActivity.
Future<bool> androidDiagnosticsIsSidecar() async =>
    (await PackageInfo.fromPlatform()).packageName != 'com.navis.app.navis';

/// Creates diagnostics storage below Android's `getExternalFilesDir(null)`.
Future<Directory> androidDiagnosticsArtifactRoot() async {
  final externalFiles = await getExternalStorageDirectory();
  if (externalFiles == null) {
    throw StateError('External app files directory is unavailable');
  }
  return await Directory(p.join(externalFiles.path, 'navis-diagnostics'))
      .create(recursive: true);
}
