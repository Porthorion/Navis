import 'dart:convert';
import 'dart:typed_data';

import 'package:navis/src/features/equalizer/data/eq_import/eq_import_result.dart';

/// Largest EQ file Navis reads.
const int eqImportMaximumBytes = 1024 * 1024;

/// Decodes an EQ file whatever editor saved it: UTF-8 with or without a BOM,
/// UTF-16 (Windows Notepad's "Unicode", with or without a BOM), or a legacy
/// Windows-1252 file.
String decodeEqImportBytes(Uint8List bytes) {
  if (bytes.length > eqImportMaximumBytes) {
    throw EqImportException(EqImportErrorCode.tooLarge);
  }
  if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) {
    return _utf8OrLegacy(Uint8List.sublistView(bytes, 3));
  }
  if (_startsWith(bytes, const [0xFF, 0xFE])) {
    return _utf16(Uint8List.sublistView(bytes, 2), littleEndian: true);
  }
  if (_startsWith(bytes, const [0xFE, 0xFF])) {
    return _utf16(Uint8List.sublistView(bytes, 2), littleEndian: false);
  }
  final guess = _guessUtf16(bytes);
  if (guess != null) return _utf16(bytes, littleEndian: guess);
  return _utf8OrLegacy(bytes);
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

/// EQ files are mostly ASCII, so BOM-less UTF-16 shows as a zero in every
/// other byte. Returns true for little endian, false for big endian.
bool? _guessUtf16(Uint8List bytes) {
  final length = bytes.length - bytes.length % 2;
  if (length < 4) return null;
  final probe = length < 512 ? length : 512;
  var zeroEven = 0;
  var zeroOdd = 0;
  for (var i = 0; i < probe; i++) {
    if (bytes[i] != 0) continue;
    if (i.isEven) {
      zeroEven++;
    } else {
      zeroOdd++;
    }
  }
  final pairs = probe ~/ 2;
  if (zeroOdd * 2 > pairs && zeroEven == 0) return true;
  if (zeroEven * 2 > pairs && zeroOdd == 0) return false;
  return null;
}

String _utf16(Uint8List bytes, {required bool littleEndian}) {
  if (bytes.length.isOdd) {
    throw EqImportException(EqImportErrorCode.unreadableText);
  }
  final units = <int>[
    for (var i = 0; i < bytes.length; i += 2)
      littleEndian
          ? bytes[i] | bytes[i + 1] << 8
          : bytes[i] << 8 | bytes[i + 1],
  ];
  return String.fromCharCodes(units);
}

String _utf8OrLegacy(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return String.fromCharCodes(bytes.map(_windows1252));
  }
}

/// Windows-1252 differs from Latin-1 only in 0x80–0x9F.
int _windows1252(int byte) {
  if (byte < 0x80 || byte > 0x9F) return byte;
  const table = <int>[
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
  ];
  return table[byte - 0x80];
}
