import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'dart:convert';

/// Best-effort audio metadata support used by permanent-download adoption.
/// FLAC/Vorbis comments are implemented without a platform plugin so Navis can
/// recover identity on every supported desktop and mobile runtime. Other
/// formats continue to use the root manifest as their authoritative identity.
/// Suffix of the temporary copy written while identity tags are added.
const String identityRewriteSuffix = '.navis-writing';

class PermanentDownloadMediaIdentity {
  static const songIdKey = 'NAVIS_SONG_ID';
  static const profileFingerprintKey = 'NAVIS_PROFILE_FINGERPRINT';
  static const int _maxCommentBytes = 1024 * 1024;

  Future<Map<String, String>> read(File file) async {
    if (file.path.toLowerCase().endsWith('.flac'))
      return _readFlacMetadata(file);
    return const <String, String>{};
  }

  /// Reads FLAC metadata only. The former implementation copied the entire
  /// audio payload into memory merely to inspect two Vorbis comments.
  Future<Map<String, String>> _readFlacMetadata(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      if (String.fromCharCodes(await handle.read(4)) != 'fLaC') {
        return const <String, String>{};
      }
      while (true) {
        final header = await handle.read(4);
        if (header.length != 4) return const <String, String>{};
        final isLast = (header[0] & 0x80) != 0;
        final type = header[0] & 0x7f;
        final length = (header[1] << 16) | (header[2] << 8) | header[3];
        if (type == 4) {
          if (length > _maxCommentBytes) return const <String, String>{};
          final bytes = await handle.read(length);
          return bytes.length == length
              ? _readVorbisComment(Uint8List.fromList(bytes))
              : const <String, String>{};
        }
        await handle.setPosition(await handle.position() + length);
        if (isLast) return const <String, String>{};
      }
    } on FileSystemException {
      return const <String, String>{};
    } finally {
      await handle?.close();
    }
  }

  /// Writes Navis identity comments into a FLAC file Navis created. Files
  /// whose comments already match are left untouched; otherwise the rewrite,
  /// which reads and copies the whole file, runs in a background isolate.
  Future<void> write({
    required File file,
    required String songId,
    required String profileFingerprint,
  }) async {
    if (!file.path.toLowerCase().endsWith('.flac')) return;
    final current = await _readFlacMetadata(file);
    if (current[songIdKey] == songId &&
        current[profileFingerprintKey] == profileFingerprint) {
      return;
    }
    final path = file.path;
    final additions = <String, String>{
      songIdKey: songId,
      profileFingerprintKey: profileFingerprint,
    };
    await Isolate.run(() => _rewriteFlacFile(path, additions));
  }

  static Future<void> _rewriteFlacFile(
    String path,
    Map<String, String> additions,
  ) async {
    final file = File(path);
    final replacement = PermanentDownloadMediaIdentity()._writeFlac(
      await file.readAsBytes(),
      additions,
    );
    if (replacement == null) return;
    final temporary = File('$path$identityRewriteSuffix');
    try {
      await temporary.writeAsBytes(replacement, flush: true);
      // Windows refuses the replace while another process (typically an
      // antivirus scan of the new file) holds it open; that clears quickly.
      for (var attempt = 1; ; attempt++) {
        try {
          await temporary.rename(path);
          return;
        } on FileSystemException {
          if (attempt == 3) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
        }
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Uint8List? _writeFlac(Uint8List bytes, Map<String, String> additions) {
    if (bytes.length < 8 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'fLaC') {
      return null;
    }
    var offset = 4;
    while (offset + 4 <= bytes.length) {
      final header = bytes[offset];
      final type = header & 0x7f;
      final length =
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      final dataStart = offset + 4;
      final dataEnd = dataStart + length;
      if (dataEnd > bytes.length) return null;
      if (type == 4) {
        final comment = _replaceVorbisComment(
          bytes.sublist(dataStart, dataEnd),
          additions,
        );
        if (comment.length > 0xFFFFFF) return null;
        final output = BytesBuilder(copy: false)
          ..add(bytes.sublist(0, offset))
          ..add(<int>[
            header,
            (comment.length >> 16) & 0xff,
            (comment.length >> 8) & 0xff,
            comment.length & 0xff,
          ])
          ..add(comment)
          ..add(bytes.sublist(dataEnd));
        return output.toBytes();
      }
      if ((header & 0x80) != 0) break;
      offset = dataEnd;
    }
    return null;
  }

  Map<String, String> _readVorbisComment(Uint8List bytes) {
    if (bytes.length < 8) return const <String, String>{};
    var offset = 0;
    final vendorLength = _readUint32Le(bytes, offset);
    offset += 4 + vendorLength;
    if (offset + 4 > bytes.length) return const <String, String>{};
    final count = _readUint32Le(bytes, offset);
    offset += 4;
    final result = <String, String>{};
    for (var index = 0; index < count; index++) {
      if (offset + 4 > bytes.length) return result;
      final length = _readUint32Le(bytes, offset);
      offset += 4;
      if (offset + length > bytes.length) return result;
      final value = utf8.decode(
        bytes.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      final equals = value.indexOf('=');
      if (equals > 0) {
        result[value.substring(0, equals).toUpperCase()] = value.substring(
          equals + 1,
        );
      }
    }
    return result;
  }

  Uint8List _replaceVorbisComment(
    Uint8List bytes,
    Map<String, String> additions,
  ) {
    var offset = 0;
    if (bytes.length < 8) return bytes;
    final vendorLength = _readUint32Le(bytes, offset);
    offset += 4;
    if (offset + vendorLength + 4 > bytes.length) return bytes;
    final vendor = bytes.sublist(offset, offset + vendorLength);
    offset += vendorLength;
    final count = _readUint32Le(bytes, offset);
    offset += 4;
    final comments = <String, String>{};
    for (var index = 0; index < count; index++) {
      if (offset + 4 > bytes.length) return bytes;
      final length = _readUint32Le(bytes, offset);
      offset += 4;
      if (offset + length > bytes.length) return bytes;
      final value = utf8.decode(
        bytes.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      final equals = value.indexOf('=');
      if (equals > 0) {
        comments[value.substring(0, equals).toUpperCase()] = value.substring(
          equals + 1,
        );
      }
    }
    comments.addAll(additions);
    final output = BytesBuilder(copy: false);
    _writeUint32Le(output, vendor.length);
    output.add(vendor);
    _writeUint32Le(output, comments.length);
    for (final entry in comments.entries) {
      final encoded = utf8.encode('${entry.key}=${entry.value}');
      _writeUint32Le(output, encoded.length);
      output.add(encoded);
    }
    return output.toBytes();
  }

  int _readUint32Le(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  void _writeUint32Le(BytesBuilder target, int value) {
    target.add(<int>[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ]);
  }
}
