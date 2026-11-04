import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_media_kit/mediakit_player.dart';
import 'package:just_audio_media_kit/src/icy_metadata.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';

class _Player extends Mock implements Player;

class _Streams extends Mock implements PlayerStream;

class _Native extends Mock implements NativePlayer;

class _Properties implements IcyPropertySource {
  @override
  Future<String> read(String property) async => '';

  @override
  Future<void> observe(
    String property,
    Future<void> Function(String) listener,
  ) async {}

  @override
  Future<void> unobserve(String property) async {}
}

/// Builds an adapter on a fake native player and returns the mpv properties it
/// set while being constructed.
Future<Map<String, String>> _propertiesSet() async {
  final player = _Player();
  final streams = _Streams();
  final native = _Native();
  final set = <String, String>{};
  when(() => player.platform).thenReturn(native);
  when(() => player.stream).thenReturn(streams);
  when(() => player.state).thenReturn(const PlayerState());
  when(() => streams.audioParams).thenAnswer((_) => const Stream.empty());
  when(() => streams.duration).thenAnswer((_) => const Stream.empty());
  when(() => streams.position).thenAnswer((_) => const Stream.empty());
  when(() => streams.buffering).thenAnswer((_) => const Stream.empty());
  when(() => streams.buffer).thenAnswer((_) => const Stream.empty());
  when(() => streams.volume).thenAnswer((_) => const Stream.empty());
  when(() => streams.completed).thenAnswer((_) => const Stream.empty());
  when(() => streams.error).thenAnswer((_) => const Stream.empty());
  when(() => streams.playlist).thenAnswer((_) => const Stream.empty());
  when(() => streams.playlistMode).thenAnswer((_) => const Stream.empty());
  when(() => streams.pitch).thenAnswer((_) => const Stream.empty());
  when(() => streams.rate).thenAnswer((_) => const Stream.empty());
  when(() => streams.log).thenAnswer((_) => const Stream.empty());
  when(() => native.setProperty(any(), any())).thenAnswer((call) async {
    set[call.positionalArguments[0] as String] =
        call.positionalArguments[1] as String;
  });
  when(() => native.command(any())).thenAnswer((_) async {});
  when(() => native.observeProperty(any(), any())).thenAnswer((_) async {});
  when(() => native.onLoadHooks).thenReturn([]);
  when(player.dispose).thenAnswer((_) async {});
  final adapter = MediaKitPlayer(
    'tls',
    player: player,
    icyPropertySource: _Properties(),
  );
  await Future<void>.delayed(Duration.zero);
  await adapter.release();
  return set;
}

void main() {
  tearDown(() {
    JustAudioMediaKit.tlsVerify = false;
    JustAudioMediaKit.tlsCaFile = null;
  });

  test('verification off sets neither TLS option', () async {
    final set = await _propertiesSet();
    expect(set, isNot(contains('tls-verify')));
    expect(set, isNot(contains('tls-ca-file')));
  });

  test('verification without a CA file sets only tls-verify', () async {
    JustAudioMediaKit.tlsVerify = true;
    final set = await _propertiesSet();
    expect(set['tls-verify'], 'yes');
    expect(set, isNot(contains('tls-ca-file')));
  });

  test('the CA file reaches libmpv as tls-ca-file', () async {
    JustAudioMediaKit.tlsVerify = true;
    JustAudioMediaKit.tlsCaFile = '/etc/ssl/cert.pem';
    final set = await _propertiesSet();
    expect(set['tls-verify'], 'yes');
    expect(set['tls-ca-file'], '/etc/ssl/cert.pem');
  });
}
