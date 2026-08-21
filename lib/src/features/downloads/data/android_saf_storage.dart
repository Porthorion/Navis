import 'dart:io';

import 'package:flutter/services.dart';

/// Android Storage Access Framework operations used by permanent downloads.
///
/// The picker deliberately returns a persisted tree URI on Android. A URI is
/// not a POSIX path, so all interaction with it must stay behind this bridge.
/// Calls are unavailable on non-Android platforms.
class AndroidSafStorage {
  const AndroidSafStorage();

  static const MethodChannel _channel = MethodChannel(
    'com.navis.app/permanent_download_storage',
  );

  static bool get isSafLocator => Platform.isAndroid;

  Future<AndroidSafTree> inspectTree(String treeUri) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'inspectTree',
      <String, Object?>{'treeUri': treeUri},
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
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'validateWritableTree',
      <String, Object?>{'treeUri': treeUri},
    );
    if (result == null) {
      throw const FileSystemException('Android did not validate the folder.');
    }
    return AndroidSafTree.fromMap(result);
  }

  Future<List<AndroidSafDocument>> listRecursively(String treeUri) async {
    final result = await _channel.invokeListMethod<dynamic>(
      'listRecursively',
      <String, Object?>{'treeUri': treeUri},
    );
    return (result ?? const <dynamic>[])
        .whereType<Map<Object?, Object?>>()
        .map(
          (value) => AndroidSafDocument.fromMap(
            value.map<String, dynamic>(
              (key, item) => MapEntry('$key', item),
            ),
          ),
        )
        .toList(growable: false);
  }

  /// Copies a document into app-private temporary storage and returns that
  /// filesystem path. This keeps parser/SQLite libraries off `content://`.
  Future<File> materialize(String uri) async {
    final path = await _channel.invokeMethod<String>(
      'materialize',
      <String, Object?>{'uri': uri},
    );
    if (path == null || path.isEmpty) {
      throw const FileSystemException('Could not read the selected document.');
    }
    return File(path);
  }

  Future<String> writeFromFile({
    required String treeUri,
    required String relativePath,
    required File source,
    String? mimeType,
    bool replace = true,
  }) async {
    final uri = await _channel.invokeMethod<String>(
      'writeFromFile',
      <String, Object?>{
        'treeUri': treeUri,
        'relativePath': relativePath,
        'sourcePath': source.path,
        'mimeType': mimeType,
        'replace': replace,
      },
    );
    if (uri == null || uri.isEmpty) {
      throw const FileSystemException(
        'Could not write into the selected folder.',
      );
    }
    return uri;
  }

  Future<void> delete(String uri) async {
    await _channel.invokeMethod<void>('delete', <String, Object?>{'uri': uri});
  }

  Future<bool> exists(String uri) async {
    return await _channel.invokeMethod<bool>(
          'exists',
          <String, Object?>{'uri': uri},
        ) ??
        false;
  }

  /// Whether [documentUri] belongs to [treeUri]. Tree and document URI text
  /// is not reliably prefix-related, so Android resolves this natively.
  Future<bool> isDescendant({
    required String treeUri,
    required String documentUri,
  }) async =>
      await _channel.invokeMethod<bool>(
        'isDescendant',
        <String, Object?>{
          'treeUri': treeUri,
          'documentUri': documentUri,
        },
      ) ??
      false;
}

class AndroidSafTree {
  const AndroidSafTree({
    required this.uri,
    required this.displayName,
    required this.canRead,
    required this.canWrite,
    required this.canReplace,
  });

  factory AndroidSafTree.fromMap(Map<String, dynamic> map) => AndroidSafTree(
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
  const AndroidSafDocument({
    required this.uri,
    required this.relativePath,
    required this.displayName,
    required this.size,
    required this.mimeType,
  });

  factory AndroidSafDocument.fromMap(Map<String, dynamic> map) =>
      AndroidSafDocument(
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
