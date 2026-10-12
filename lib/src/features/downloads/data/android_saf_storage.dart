import 'dart:io';

import 'package:flutter/services.dart';

/// Android Storage Access Framework operations used by permanent downloads.
///
/// The picker returns a tree URI on Android, which [persistTree] keeps. A URI is
/// not a POSIX path, so all interaction with it must stay behind this bridge.
/// Calls are unavailable on non-Android platforms.
class AndroidSafStorage {
  const new();

  static const MethodChannel _channel = MethodChannel(
    'com.navis.app/permanent_download_storage',
  );

  static const MethodChannel _playbackChannel = MethodChannel(
    'com.navis.app/permanent_download_playback',
  );

  static bool get isSafLocator => Platform.isAndroid;

  /// Keeps read/write access to a picked tree across restarts and updates.
  Future<void> persistTree(String treeUri) => _invoke(
    () => _channel.invokeMethod<void>('persistTree', <String, Object?>{
      'treeUri': treeUri,
    }),
    'Navis could not keep access to the selected Android folder.',
  );

  Future<AndroidSafTree> inspectTree(String treeUri) async {
    final result = await _invoke(
      () => _channel.invokeMapMethod<String, dynamic>(
        'inspectTree',
        <String, Object?>{'treeUri': treeUri},
      ),
      'Could not inspect the selected Android folder.',
    );
    if (result == null) {
      throw const FileSystemException('Android did not return folder details.');
    }
    return AndroidSafTree.fromMap(result);
  }

  /// Confirms that a provider can create, write, and remove a Navis-owned
  /// probe document. This is intentionally separate from [inspectTree] so
  /// rendering a selected folder name never mutates the tree.
  Future<AndroidSafTree> validateWritableTree(String treeUri) async {
    final result = await _invoke(
      () => _channel.invokeMapMethod<String, dynamic>(
        'validateWritableTree',
        <String, Object?>{'treeUri': treeUri},
      ),
      'Navis can no longer access the selected Android folder.',
    );
    if (result == null) {
      throw const FileSystemException('Android did not validate the folder.');
    }
    return AndroidSafTree.fromMap(result);
  }

  Future<List<AndroidSafDocument>> listRecursively(String treeUri) async {
    final result = await _invoke(
      () => _channel.invokeListMethod<dynamic>(
        'listRecursively',
        <String, Object?>{'treeUri': treeUri},
      ),
      'Navis can no longer list the selected Android folder.',
    );
    return (result ?? const <dynamic>[])
        .whereType<Map<Object?, Object?>>()
        .map(
          (value) => AndroidSafDocument.fromMap(
            value.map<String, dynamic>((key, item) => MapEntry('$key', item)),
          ),
        )
        .toList(growable: false);
  }

  /// The document at [relativePath] below [treeUri], or null when there is
  /// none. Resolves one path component per provider query instead of listing
  /// the whole tree.
  Future<String?> findDocument({
    required String treeUri,
    required String relativePath,
  }) => _invoke(
    () => _channel.invokeMethod<String>('findDocument', <String, Object?>{
      'treeUri': treeUri,
      'relativePath': relativePath,
    }),
    'Could not read the selected Android folder.',
  );

  /// Copies a document into app-private temporary storage and returns that
  /// filesystem path. This keeps parser/SQLite libraries off `content://`.
  Future<File> materialize(String uri) async {
    final path = await _invoke(
      () => _channel.invokeMethod<String>('materialize', <String, Object?>{
        'uri': uri,
      }),
      'Could not read the selected document.',
    );
    if (path == null || path.isEmpty) {
      throw const FileSystemException('Could not read the selected document.');
    }
    return File(path);
  }

  /// Reads Navis identity comments from a FLAC document without staging its
  /// audio payload in app-private storage.
  Future<Map<String, String>> readFlacIdentity(String uri) async {
    final result = await _invoke(
      () => _channel.invokeMapMethod<String, dynamic>(
        'readFlacIdentity',
        <String, Object?>{'uri': uri},
      ),
      'Could not read download identity metadata.',
    );
    return result == null
        ? const <String, String>{}
        : result.map((key, value) => MapEntry(key, '$value'));
  }

  Future<String> writeFromFile({
    required String treeUri,
    required String relativePath,
    required File source,
    String? mimeType,
    bool replace = true,
  }) async {
    final uri = await _invoke(
      () => _channel.invokeMethod<String>('writeFromFile', <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
        'sourcePath': source.path,
        'mimeType': mimeType,
        'replace': replace,
      }),
      'Could not write into the selected folder.',
    );
    if (uri == null || uri.isEmpty) {
      throw const FileSystemException(
        'Could not write into the selected folder.',
      );
    }
    return uri;
  }

  Future<void> delete(String uri) async {
    await _invoke(
      () =>
          _channel.invokeMethod<void>('delete', <String, Object?>{'uri': uri}),
      'Could not remove the selected document.',
    );
  }

  Future<bool> exists(String uri) async {
    return await _invoke<bool?>(
          () => _playbackChannel.invokeMethod<bool>('exists', <String, Object?>{
            'uri': uri,
          }),
          'Could not check the selected document.',
        ) ??
        false;
  }

  Future<T> _invoke<T>(Future<T> Function() call, String message) async {
    try {
      return await call();
    } on PlatformException catch (error) {
      final code = switch (error.code) {
        'NO_SPACE' => 28,
        'PERMISSION_DENIED' => 13,
        _ => null,
      };
      throw FileSystemException(
        error.message ?? message,
        '',
        code == null ? null : OSError(error.code, code),
      );
    }
  }

  /// Whether [documentUri] belongs to [treeUri]. Tree and document URI text
  /// is not reliably prefix-related, so Android resolves this natively.
  Future<bool> isDescendant({
    required String treeUri,
    required String documentUri,
  }) async =>
      await _channel.invokeMethod<bool>('isDescendant', <String, Object?>{
        'treeUri': treeUri,
        'documentUri': documentUri,
      }) ??
      false;

  /// Returns the profile-sidecar-only deterministic tree used by Android
  /// diagnostics. Stable/debug builds reject this call natively.
  Future<String> diagnosticsFixtureTree() async {
    final uri = await _channel.invokeMethod<String>('diagnosticsFixtureTree');
    if (uri == null || !uri.startsWith('content://')) {
      throw const FileSystemException(
        'Android diagnostics fixture is unavailable.',
      );
    }
    return uri;
  }

  // Keep the existing method and callback call contract for callers.
  // ignore: avoid_positional_boolean_parameters
  Future<void> diagnosticsFixtureSetReadDenied(bool denied) =>
      _channel.invokeMethod<void>(
        'diagnosticsFixtureSetReadDenied',
        <String, Object?>{'denied': denied},
      );

  /// Stages a copy without a sidecar entry in the profile-only diagnostics
  /// tree. It is intentionally unavailable to ordinary builds.
  Future<void> diagnosticsFixtureStageUnindexedCopy() =>
      _channel.invokeMethod<void>('diagnosticsFixtureStageUnindexedCopy');
}

class AndroidSafTree {
  const new({
    required this.uri,
    required this.displayName,
    required this.canRead,
    required this.canWrite,
    required this.canReplace,
  });

  factory fromMap(Map<String, dynamic> map) => AndroidSafTree(
    uri: map['uri'] as String,
    displayName: map['displayName'] as String? ?? 'Selected folder',
    canRead: map['canRead'] == true,
    canWrite: map['canWrite'] == true,
    canReplace: map['canReplace'] == true,
  );

  final String uri;
  final String displayName;
  final bool canRead;
  final bool canWrite;
  final bool canReplace;
}

class AndroidSafDocument {
  const new({
    required this.uri,
    required this.relativePath,
    required this.displayName,
    required this.size,
    required this.mimeType,
  });

  factory fromMap(Map<String, dynamic> map) => AndroidSafDocument(
    uri: map['uri'] as String,
    relativePath: map['relativePath'] as String,
    displayName: map['displayName'] as String,
    size: (map['size'] as num?)?.toInt() ?? 0,
    mimeType: map['mimeType'] as String?,
  );

  final String uri;
  final String relativePath;
  final String displayName;
  final int size;
  final String? mimeType;
}

/// Validates a stored-audio locator according to its storage kind.
///
/// Android SAF documents are content URIs: `File.exists()` is always false for
/// them, which would make a valid permanent download look deleted. SAF rows
/// are validated through the platform bridge; filesystem rows stay on
/// `dart:io`.
Future<bool> storedAudioExists({
  required String locator,
  required String? storageKind,
}) async {
  final isSaf = storageKind == 'androidSaf' || locator.startsWith('content://');
  if (!isSaf) {
    try {
      final file = File(locator);
      // Keep metadata access asynchronous so storage latency cannot stall UI.
      // ignore: avoid_slow_async_io
      return await file.exists() && await file.length() > 0;
    } on FileSystemException {
      return false;
    }
  }
  if (!AndroidSafStorage.isSafLocator) {
    return false;
  }
  try {
    return await const AndroidSafStorage().exists(locator);
  } on FileSystemException {
    return false;
  }
}
