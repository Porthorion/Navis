import 'package:flutter_test/flutter_test.dart';
// The batch is internal to the vendored media_kit bridge.
import 'package:just_audio_media_kit/src/audio_request_batch.dart';

void main() {
  test('speed and pitch set in one turn are applied once, together', () async {
    final applied = <(double?, double?, String?)>[];
    final batch = AudioRequestBatch<String>(({rate, pitch, equalizer}) async {
      applied.add((rate, pitch, equalizer));
    });

    await Future.wait(<Future<void>>[
      batch.request(rate: 1.5),
      batch.request(pitch: 0.9),
    ]);

    expect(applied, <(double?, double?, String?)>[(1.5, 0.9, null)]);
  });

  test('a later request starts a new application', () async {
    final applied = <(double?, double?, String?)>[];
    final batch = AudioRequestBatch<String>(({rate, pitch, equalizer}) async {
      applied.add((rate, pitch, equalizer));
    });

    await batch.request(rate: 1.25);
    await batch.request(equalizer: 'bass');

    expect(applied, <(double?, double?, String?)>[
      (1.25, null, null),
      (null, null, 'bass'),
    ]);
  });

  test('every merged caller sees a failure', () async {
    final batch = AudioRequestBatch<String>(({rate, pitch, equalizer}) async {
      throw StateError('graph rejected');
    });

    final speed = batch.request(rate: 2);
    final pitch = batch.request(pitch: 2);

    await expectLater(speed, throwsStateError);
    await expectLater(pitch, throwsStateError);
  });
}
