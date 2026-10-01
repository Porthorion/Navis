import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/src/set_property_io.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';

class _Player extends Mock implements Player;

class _NativePlayer extends Mock implements NativePlayer;

void main() {
  const expected =
      '@navis_tempo:scaletempo:scale=1.0,@navis_eq:lavfi=[volume=-3.0dB:precision=double,biquad=b0=0.95:b1=-1.8:b2=0.9:a0=1:a1=-1.8:a2=0.85]';
  const actual =
      '@navis_tempo:scaletempo="scale=1.0",@navis_eq:lavfi="graph=volume=-3.0dB:precision=double,biquad=b0=0.95:b1=-1.8:b2=0.9:a0=1:a1=-1.8:a2=0.85"';
  late _Player player;
  late _NativePlayer native;
  setUp(() {
    player = _Player();
    native = _NativePlayer();
    when(() => player.platform).thenReturn(native);
    when(() => native.getProperty('speed')).thenAnswer((_) async => '1.0');
  });
  test('native serialization retains exact authored coefficients', () async {
    when(() => native.getProperty('af')).thenAnswer((_) async => actual);
    await verifyOwnedAudioChain(player, expected, 1);
  });
  test('existing EQ label cannot conceal a rejected curve change', () async {
    when(() => native.getProperty('af'))
        .thenAnswer((_) async => actual.replaceFirst('b0=0.95', 'b0=0.99'));
    await expectLater(
      verifyOwnedAudioChain(player, expected, 1),
      throwsStateError,
    );
  });
  test('rejected bypass cannot report the remaining EQ as disabled', () async {
    when(() => native.getProperty('af')).thenAnswer((_) async => actual);
    await expectLater(
      verifyOwnedAudioChain(player, '@navis_tempo:scaletempo:scale=1.0', 1),
      throwsStateError,
    );
  });
}
