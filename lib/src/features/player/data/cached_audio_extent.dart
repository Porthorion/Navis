import 'dart:io';
import 'dart:typed_data';

/// How much audio the start of a partly downloaded Ogg (Opus, Vorbis) or FLAC
/// file holds, read exactly from the file's own framing: the granule of the
/// last complete Ogg page, or the sample index of the last verified FLAC
/// frame. Null when the format is another one or nothing complete is found, so
/// callers fall back to their estimate.
///
/// [head] is the first bytes of the file (the stream headers) and [tail] the
/// last ones (the newest pages or frames).
Duration? cachedAudioExtent(Uint8List head, Uint8List tail) {
  if (_startsWith(head, 0, _oggS)) return _oggExtent(head, tail);
  if (_startsWith(head, 0, _flac)) return _flacExtent(head, tail);
  return null;
}

/// [cachedAudioExtent] for the file at [path]: reads its first 4 KB and last
/// 128 KB. Never throws; any I/O failure (a part file renamed on completion,
/// a file locked for writing) returns null.
Future<Duration?> readCachedAudioExtent(String path) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final length = await file.length();
    final head = await file.read(length < _headBytes ? length : _headBytes);
    final tailStart = length < _tailBytes ? 0 : length - _tailBytes;
    await file.setPosition(tailStart);
    final tail = await file.read(length - tailStart);
    return cachedAudioExtent(head, tail);
  } on Object {
    return null;
  } finally {
    try {
      await file?.close();
    } on Object {
      // Closing a file that failed to open or read cannot matter.
    }
  }
}

const _headBytes = 4096;
const _tailBytes = 128 * 1024;
const _oggS = [0x4F, 0x67, 0x67, 0x53];
const _flac = [0x66, 0x4C, 0x61, 0x43];

bool _startsWith(Uint8List bytes, int at, List<int> prefix) {
  if (at < 0 || at + prefix.length > bytes.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[at + i] != prefix[i]) return false;
  }
  return true;
}

// ── Ogg ─────────────────────────────────────────────────────────────────

Duration? _oggExtent(Uint8List head, Uint8List tail) {
  // The first page holds one packet: the Opus or Vorbis identification header.
  final segments = head.length > 26 ? head[26] : 0;
  final payload = 27 + segments;
  final int rate;
  var preSkip = 0;
  if (_startsWith(head, payload, 'OpusHead'.codeUnits) &&
      head.length >= payload + 12) {
    rate = 48000;
    preSkip = ByteData.sublistView(head).getUint16(payload + 10, Endian.little);
  } else if (_startsWith(head, payload, [1, ...'vorbis'.codeUnits]) &&
      head.length >= payload + 16) {
    rate = ByteData.sublistView(head).getUint32(payload + 12, Endian.little);
  } else {
    return null;
  }
  if (rate <= 0) return null;
  final granule = _lastOggGranule(tail);
  if (granule == null) return null;
  final samples = granule > preSkip ? granule - preSkip : 0;
  return Duration(microseconds: samples * 1000000 ~/ rate);
}

/// The granule of the last complete page in [tail] that finishes a packet.
/// A page counts only if it fits the buffer and is followed by `OggS` (or the
/// start of one, or the end), which rules out `OggS` bytes inside a payload.
int? _lastOggGranule(Uint8List tail) {
  final data = ByteData.sublistView(tail);
  for (var at = tail.length - 27; at >= 0; at--) {
    if (!_startsWith(tail, at, _oggS) || tail[at + 4] != 0) continue;
    final segments = tail[at + 26];
    if (at + 27 + segments > tail.length) continue;
    var size = 27 + segments;
    for (var i = 0; i < segments; i++) {
      size += tail[at + 27 + i];
    }
    final end = at + size;
    if (end > tail.length) continue;
    final left = tail.length - end;
    if (left > 0 &&
        !_startsWith(tail, end, _oggS.sublist(0, left < 4 ? left : 4))) {
      continue;
    }
    final granule = data.getInt64(at + 6, Endian.little);
    if (granule >= 0) return granule;
  }
  return null;
}

// ── FLAC ────────────────────────────────────────────────────────────────

Duration? _flacExtent(Uint8List head, Uint8List tail) {
  // STREAMINFO must be the first metadata block (type 0, 34 bytes).
  if (head.length < 4 + 4 + 34 || (head[4] & 0x7F) != 0) return null;
  final info = ByteData.sublistView(head, 8, 8 + 34);
  final minBlock = info.getUint16(0);
  final maxBlock = info.getUint16(2);
  final rate = info.getUint32(10) >> 12;
  if (rate <= 0 || maxBlock <= 0) return null;
  final fixed = minBlock == maxBlock;

  // Every header in the tail that passes its CRC-8; a header counts only once
  // it continues a verified one, so a chance sync inside the audio is dropped.
  int? previousStart;
  int? previousSize;
  int? last;
  for (var at = 0; at + 6 <= tail.length; at++) {
    if (tail[at] != 0xFF || (tail[at + 1] & 0xFE) != 0xF8) continue;
    final frame = _flacHeader(tail, at, fixed: fixed, maxBlock: maxBlock);
    if (frame == null) continue;
    final (start, size) = frame;
    if (previousStart != null && start == previousStart + previousSize!) {
      last = start;
    }
    previousStart = start;
    previousSize = size;
  }
  return last == null ? null : Duration(microseconds: last * 1000000 ~/ rate);
}

/// The first sample and block size of the frame whose header starts at [at],
/// or null when the header is invalid, cut off, or of the wrong strategy.
(int, int)? _flacHeader(
  Uint8List bytes,
  int at, {
  required bool fixed,
  required int maxBlock,
}) {
  final variable = (bytes[at + 1] & 1) == 1;
  if (variable == fixed) return null;
  final blockCode = bytes[at + 2] >> 4;
  final rateCode = bytes[at + 2] & 0x0F;
  final channels = bytes[at + 3] >> 4;
  final sampleSizeCode = (bytes[at + 3] >> 1) & 7;
  if (blockCode == 0 ||
      rateCode == 15 ||
      channels > 10 ||
      sampleSizeCode == 3 ||
      (bytes[at + 3] & 1) != 0) {
    return null;
  }
  // UTF-8 style coded frame or sample number.
  final lead = bytes[at + 4];
  var extra = 0;
  if (lead >= 0xC0) {
    extra = 1;
    while (extra < 7 && (lead & (0x80 >> (extra + 1))) != 0) {
      extra++;
    }
  } else if (lead >= 0x80) {
    return null;
  }
  if (extra > (variable ? 6 : 5)) return null;
  var end = at + 5 + extra;
  var number = extra == 0 ? lead : lead & (0x3F >> extra);
  if (end > bytes.length) return null;
  for (var i = 1; i <= extra; i++) {
    final next = bytes[at + 4 + i];
    if ((next & 0xC0) != 0x80) return null;
    number = (number << 6) | (next & 0x3F);
  }
  final int size;
  if (blockCode == 1) {
    size = 192;
  } else if (blockCode <= 5) {
    size = 576 << (blockCode - 2);
  } else if (blockCode >= 8) {
    size = 256 << (blockCode - 8);
  } else {
    final width = blockCode == 6 ? 1 : 2;
    if (end + width > bytes.length) return null;
    size = (width == 1 ? bytes[end] : (bytes[end] << 8) | bytes[end + 1]) + 1;
    end += width;
  }
  end += switch (rateCode) {
    12 => 1,
    13 || 14 => 2,
    _ => 0,
  };
  if (end >= bytes.length) return null;
  var crc = 0;
  for (var i = at; i < end; i++) {
    crc ^= bytes[i];
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  if (crc != bytes[end]) return null;
  return (fixed ? number * maxBlock : number, size);
}
