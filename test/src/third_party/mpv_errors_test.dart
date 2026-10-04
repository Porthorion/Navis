import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/mpv_errors.dart';

void main() {
  test('decoder glitches are recoverable, source failures are not', () {
    expect(isRecoverableMpvDecodeError('Error decoding audio.'), isTrue);
    expect(isRecoverableMpvDecodeError('Error while decoding frame!'), isTrue);
    expect(
      isRecoverableMpvDecodeError('Failed to open https://example.com/x.'),
      isFalse,
    );
    expect(
      isRecoverableMpvDecodeError('Failed to recognize file format.'),
      isFalse,
    );
    expect(isRecoverableMpvDecodeError('tcp: Connection refused'), isFalse);
  });
}
