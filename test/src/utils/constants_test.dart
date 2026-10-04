import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/constants.dart';

/// Hex of `bytes` XOR `pad`, the way tool/lib/lastfm_key_defines.sh masks.
String _mask(String key, List<int> pad) {
  final out = StringBuffer();
  for (var i = 0; i < key.length; i++) {
    out.write((key.codeUnitAt(i) ^ pad[i]).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  const fakeKey = '0123456789abcdef0123456789abcdef';
  final pad = List<int>.generate(fakeKey.length, (i) => (i * 37 + 11) & 0xff);

  group('AppConstants.unmaskLastFmApiKey', () {
    test('recovers the key from a masked pair', () {
      expect(
        AppConstants.unmaskLastFmApiKey(
          masked: _mask(fakeKey, pad),
          pad: _hex(pad),
        ),
        fakeKey,
      );
    });

    test('masked text never contains the plaintext key', () {
      expect(_mask(fakeKey, pad), isNot(contains(fakeKey)));
    });

    test('accepts a pad longer than the masked key', () {
      expect(
        AppConstants.unmaskLastFmApiKey(
          masked: _mask(fakeKey, pad),
          pad: '${_hex(pad)}ffff',
        ),
        fakeKey,
      );
    });

    test('returns empty for a pad shorter than the masked key', () {
      expect(
        AppConstants.unmaskLastFmApiKey(
          masked: _mask(fakeKey, pad),
          pad: _hex(pad.sublist(0, 4)),
        ),
        isEmpty,
      );
    });

    test('returns empty for malformed hex', () {
      expect(
        AppConstants.unmaskLastFmApiKey(masked: 'abc', pad: 'abc'),
        isEmpty,
      );
      expect(AppConstants.unmaskLastFmApiKey(masked: 'zz', pad: '00'), isEmpty);
    });

    test('returns empty when the pad belongs to another build', () {
      final otherPad = List<int>.generate(fakeKey.length, (i) => 0x80 | i);
      expect(
        AppConstants.unmaskLastFmApiKey(
          masked: _mask(fakeKey, pad),
          pad: _hex(otherPad),
        ),
        isEmpty,
      );
    });

    test('returns empty when either half is missing', () {
      expect(
        AppConstants.unmaskLastFmApiKey(masked: _mask(fakeKey, pad), pad: ''),
        isEmpty,
      );
      expect(
        AppConstants.unmaskLastFmApiKey(masked: '', pad: _hex(pad)),
        isEmpty,
      );
    });
  });

  group('AppConstants.resolveLastFmApiKey', () {
    final masked = _mask(fakeKey, pad);
    final padHex = _hex(pad);

    test('prefers the masked pair over the plain key', () {
      expect(
        AppConstants.resolveLastFmApiKey(
          masked: masked,
          pad: padHex,
          plain: 'plain-dev-key',
        ),
        fakeKey,
      );
    });

    test('falls back to the plain dev key when the pair is absent', () {
      expect(
        AppConstants.resolveLastFmApiKey(
          masked: '',
          pad: '',
          plain: ' plain-dev-key ',
        ),
        'plain-dev-key',
      );
    });

    test('is empty in a keyless build', () {
      expect(
        AppConstants.resolveLastFmApiKey(masked: '', pad: '', plain: ''),
        isEmpty,
      );
    });

    test('a half-present pair is empty rather than the plain key', () {
      expect(
        AppConstants.resolveLastFmApiKey(
          masked: masked,
          pad: '',
          plain: 'plain-dev-key',
        ),
        isEmpty,
      );
    });
  });

  test('no define leaves the bundled key empty', () {
    expect(AppConstants.lastFmApiKey, isEmpty);
  });
}
