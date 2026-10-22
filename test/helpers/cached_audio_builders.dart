import 'dart:typed_data';

/// Synthetic Ogg and FLAC bytes for the cached-extent tests. They carry only
/// what the extent reader inspects; the audio payload is filler without 0xFF
/// or `OggS` bytes, so only real structure can match.

const int _filler = 0x11;

/// One Ogg page holding a single packet of [payload] (at most 255*255 bytes).
Uint8List oggPage(
  List<int> payload, {
  required int granule,
  int sequence = 0,
  int version = 0,
}) {
  final lacing = <int>[
    for (var i = 0; i < payload.length ~/ 255; i++) 255,
    payload.length % 255,
  ];
  final out = BytesBuilder()
    ..add('OggS'.codeUnits)
    ..addByte(version)
    ..addByte(0);
  final granuleBytes = ByteData(8)..setInt64(0, granule, Endian.little);
  out.add(granuleBytes.buffer.asUint8List());
  final ids = ByteData(12)
    ..setUint32(0, 1, Endian.little)
    ..setUint32(4, sequence, Endian.little);
  out
    ..add(ids.buffer.asUint8List())
    ..addByte(lacing.length)
    ..add(lacing)
    ..add(payload);
  return out.toBytes();
}

Uint8List opusHeadPage({int preSkip = 312}) {
  final head = ByteData(19)
    ..setUint8(8, 1)
    ..setUint8(9, 2)
    ..setUint16(10, preSkip, Endian.little)
    ..setUint32(12, 44100, Endian.little);
  final bytes = head.buffer.asUint8List();
  bytes.setRange(0, 8, 'OpusHead'.codeUnits);
  return oggPage(bytes, granule: 0);
}

Uint8List vorbisIdPage({int rate = 44100}) {
  final id = ByteData(30)
    ..setUint8(0, 1)
    ..setUint8(11, 2)
    ..setUint32(12, rate, Endian.little);
  final bytes = id.buffer.asUint8List();
  bytes.setRange(1, 7, 'vorbis'.codeUnits);
  return oggPage(bytes, granule: 0);
}

/// An audio page of [size] filler bytes ending at [granule].
Uint8List oggAudioPage(int granule, {int size = 300, int sequence = 1}) =>
    oggPage(
      List<int>.filled(size, _filler),
      granule: granule,
      sequence: sequence,
    );

/// `fLaC` and a STREAMINFO block (the last metadata block).
Uint8List flacHead({
  int minBlock = 4096,
  int maxBlock = 4096,
  int rate = 44100,
}) {
  final info = ByteData(34)
    ..setUint16(0, minBlock)
    ..setUint16(2, maxBlock)
    ..setUint32(10, (rate << 12) | (1 << 9) | (15 << 4));
  return Uint8List.fromList([
    ...'fLaC'.codeUnits,
    0x80,
    0,
    0,
    34,
    ...info.buffer.asUint8List(),
  ]);
}

int crc8(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  return crc;
}

List<int> _codedNumber(int value) {
  if (value < 0x80) return [value];
  var extra = 1;
  while (value >= (1 << (6 * extra + 6 - extra))) {
    extra++;
  }
  final lead = (0xFF << (7 - extra)) & 0xFF;
  return [
    lead | (value >> (6 * extra)),
    for (var i = extra - 1; i >= 0; i--) 0x80 | ((value >> (6 * i)) & 0x3F),
  ];
}

/// A FLAC frame header with a valid CRC-8, then [body] bytes of filler.
/// [number] is the frame number (fixed) or the first sample (variable).
/// The block size is 4096 (code 12) unless [blockSizeCode] says otherwise.
Uint8List flacFrame(
  int number, {
  bool variable = false,
  int blockSizeCode = 12,
  List<int> blockSizeBytes = const <int>[],
  int body = 400,
  bool badCrc = false,
}) {
  final header = <int>[
    0xFF,
    if (variable) 0xF9 else 0xF8,
    (blockSizeCode << 4),
    (1 << 4) | (4 << 1),
    ..._codedNumber(number),
    ...blockSizeBytes,
  ];
  final crc = crc8(header);
  return Uint8List.fromList([
    ...header,
    if (badCrc) crc ^ 0x5A else crc,
    ...List<int>.filled(body, _filler),
  ]);
}

Uint8List concat(Iterable<List<int>> parts) =>
    Uint8List.fromList([for (final part in parts) ...part]);
