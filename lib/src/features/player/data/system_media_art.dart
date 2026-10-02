import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:navis/src/utils/credential_redaction.dart';
import 'package:path/path.dart' as p;

/// The `MediaItem.extras` key of the local cover file that
/// `NavisAudioHandler` caches for the current song.
const artCacheFileExtra = 'artCacheFile';

/// The local cover file cached for [item], if any.
String? systemArtFile(MediaItem item) {
  final cached = item.extras?[artCacheFileExtra];
  return cached is String && cached.isNotEmpty ? cached : null;
}

/// The cover to show in the system media controls (MPRIS) for [item]: the
/// local cover file once it is cached, otherwise [MediaItem.artUri] only when
/// it carries no account credentials (radio artwork). A Subsonic cover URL is
/// never published, since other processes can read it.
String? systemArtUrl(MediaItem item) {
  final cached = systemArtFile(item);
  if (cached != null) return Uri.file(cached).toString();
  final artUri = item.artUri;
  if (artUri == null || uriCarriesCredentials(artUri)) return null;
  return artUri.toString();
}

/// [path] when its extension matches its image bytes, otherwise a copy named
/// for the image type. The art cache names every cover `.jpg`, and Windows
/// picks the cover decoder by extension, so a PNG cover would otherwise leave
/// the media overlay without an image.
String typedSystemArtFile(String path) {
  final extension = _imageExtension(path);
  if (extension == null || p.extension(path).toLowerCase() == extension) {
    return path;
  }
  final typed = p.setExtension(path, extension);
  try {
    final source = File(path);
    final target = File(typed);
    if (!target.existsSync() ||
        target.lastModifiedSync().isBefore(source.lastModifiedSync())) {
      source.copySync(typed);
    }
    return typed;
  } on FileSystemException {
    return path;
  }
}

String? _imageExtension(String path) {
  final List<int> head;
  try {
    final file = File(path).openSync();
    try {
      head = file.readSync(12);
    } finally {
      file.closeSync();
    }
  } on FileSystemException {
    return null;
  }
  bool startsWith(List<int> bytes, [int offset = 0]) =>
      head.length >= offset + bytes.length &&
      Iterable<int>.generate(bytes.length)
          .every((i) => head[offset + i] == bytes[i]);
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return '.jpg';
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return '.png';
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return '.gif';
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return '.webp';
  }
  if (startsWith(const [0x42, 0x4D])) return '.bmp';
  return null;
}
