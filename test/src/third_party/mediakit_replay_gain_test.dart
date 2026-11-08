import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/mediakit_player.dart';
import 'package:just_audio_media_kit/src/equalizer_chain.dart';
import 'package:just_audio_media_kit/src/icy_metadata.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mocktail/mocktail.dart';

class _Player extends Mock implements Player;

class _Streams extends Mock implements PlayerStream;

class _NativePlayer extends Mock implements NativePlayer;

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

const _a = 'https://music.example.invalid/a';
const _b = 'https://music.example.invalid/b';
const _rg = '@navis_rg:lavfi=[volume=';

EqualizerConfigurationMessage _eq({bool enabled = false}) =>
    EqualizerConfigurationMessage(
      enabled: enabled,
      preampDb: 0,
      autoHeadroom: false,
      filters: const [],
    );

void main() {
  late _Player player;
  late _NativePlayer native;
  late Map<String, String> properties;

  /// What the synchronous libmpv calls were asked to do, in order.
  late List<String> sync;

  /// The `on_load` hooks the adapter registered on the native player.
  late List<Future<void> Function()> hooks;
  MediaKitPlayer? adapter;

  LoadRequest queue(Map<String, double?> levels) => LoadRequest(
    audioSourceMessage: ConcatenatingAudioSourceMessage(
      id: 'queue',
      children: [
        for (final entry in levels.entries)
          ProgressiveAudioSourceMessage(
            id: entry.key,
            uri: entry.key,
            headers: null,
            replayGainDb: entry.value,
          ),
      ],
      useLazyPreparation: false,
      shuffleOrder: [for (var i = 0; i < levels.length; i++) i],
    ),
    initialIndex: 0,
    initialPosition: null,
  );

  Future<MediaKitPlayer> newAdapter({
    EqualizerConfigurationMessage? equalizer,
    Map<String, double?> levels = const {_a: -9, _b: null},
    bool commandOk = true,
    bool? replayGainFilter,
    double? sampleRate,
  }) async {
    final streams = _Streams();
    final playlist = Playlist([for (final uri in levels.keys) Media(uri)]);
    when(() => player.stream).thenReturn(streams);
    when(() => player.state).thenReturn(PlayerState(playlist: playlist));
    when(() => streams.audioParams).thenAnswer(
      (_) => sampleRate == null
          ? const Stream.empty()
          : Stream.value(AudioParams(sampleRate: sampleRate.toInt())),
    );
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
    when(() => player.open(any(), play: any(named: 'play')))
        .thenAnswer((_) async {});
    when(player.dispose).thenAnswer((_) async {});
    when(() => player.add(any())).thenAnswer((_) async {});
    when(() => player.move(any(), any())).thenAnswer((_) async {});
    final created = MediaKitPlayer(
      'test',
      player: player,
      equalizer: equalizer,
      icyPropertySource: _Properties(),
      replayGainFilter: replayGainFilter,
      commandSync: (line) {
        sync.add(line);
        return commandOk;
      },
      setPropertySync: (name, value) {
        sync.add('$name=$value');
        return true;
      },
    );
    adapter = created;
    await created.load(queue(levels));
    return created;
  }

  setUp(() {
    player = _Player();
    native = _NativePlayer();
    properties = {};
    sync = [];
    hooks = [];
    when(() => player.platform).thenReturn(native);
    when(() => native.onLoadHooks).thenReturn(hooks);
    when(() => native.observeProperty(any(), any())).thenAnswer((_) async {});
    when(() => native.command(any())).thenAnswer((_) async {});
    when(() => native.setProperty(any(), any())).thenAnswer((call) async {
      properties[call.positionalArguments[0] as String] =
          '${call.positionalArguments[1]}';
    });
    when(() => native.getProperty(any())).thenAnswer(
      (call) async => properties[call.positionalArguments[0] as String] ?? '',
    );
    registerFallbackValue(Playlist(const []));
    registerFallbackValue(Media(_a));
  });

  tearDown(() async {
    await adapter?.release();
    adapter = null;
  });

  group('the chain', () {
    test('the ReplayGain filter comes first and is always present', () {
      final plain = EqualizerChain.compile(
        _eq(),
        speed: 1,
        pitch: 1,
      ).withReplayGain(-6);
      expect(
        plain,
        '$_rg-6.000dB:precision=float],@navis_tempo:scaletempo:scale=1.0',
      );
      final withEq = EqualizerChain.compile(
        EqualizerConfigurationMessage(
          enabled: true,
          preampDb: -1,
          autoHeadroom: false,
          filters: const [
            EqualizerFilterMessage(
              type: 'peaking',
              frequencyHz: 1000,
              gainDb: 3,
              q: 1,
              enabled: true,
            ),
          ],
        ),
        speed: 1,
        pitch: 1,
        sampleRate: 44100,
      ).withReplayGain(3);
      expect(withEq, startsWith('${_rg}3.000dB:precision=float],@navis_tempo'));
      expect(withEq, contains('@navis_eq:lavfi=['));
    });
  });

  group('without the EQ pipeline', () {
    test('speed and pitch keep the playing level in the chain', () async {
      final mpv = await newAdapter();
      mpv.replayGainFiltersForLoad(_a);
      await mpv.setSpeed(SetSpeedRequest(speed: 1.25));
      expect(properties['af'], startsWith('$_rg-9.000dB'));
      expect(properties['af'], contains('scale=1.25'));
      await mpv.setPitch(SetPitchRequest(pitch: 1.1));
      expect(properties['af'], startsWith('$_rg-9.000dB'));
      verifyNever(() => player.setRate(any()));
      verifyNever(() => player.setPitch(any()));
    });
  });

  group('the on_load hook', () {
    test('writes the entering file chain: join, jump back and seek', () async {
      final mpv = await newAdapter(equalizer: _eq());
      expect(mpv.replayGainFiltersForLoad(_a), startsWith('$_rg-9.000dB'));
      expect(mpv.replayGainFiltersForLoad(_b), startsWith('${_rg}0.000dB'));
      // Jumping back to the song that played with a cut.
      expect(mpv.replayGainFiltersForLoad(_a), startsWith('$_rg-9.000dB'));
    });

    test('a file outside the queue (radio) plays at 0 dB', () async {
      final mpv = await newAdapter(equalizer: _eq());
      mpv.replayGainFiltersForLoad(_a);
      expect(
        mpv.replayGainFiltersForLoad('https://radio.example.invalid/live'),
        startsWith('${_rg}0.000dB'),
      );
    });

    test('an inserted source brings its own level', () async {
      final mpv = await newAdapter(equalizer: _eq());
      const c = 'https://music.example.invalid/c';
      await mpv.concatenatingInsertAll(
        ConcatenatingInsertAllRequest(
          id: 'queue',
          index: 2,
          children: [
            ProgressiveAudioSourceMessage(
              id: c,
              uri: c,
              headers: null,
              replayGainDb: 4,
            ),
          ],
          shuffleOrder: const [0, 1, 2],
        ),
      );
      expect(mpv.replayGainFiltersForLoad(c), startsWith('${_rg}4.000dB'));
    });
  });

  group('the load path (what the review mutations delete)', () {
    test('the adapter registers the ReplayGain on_load hook', () async {
      final withHook = await newAdapter(equalizer: _eq());
      final registered = hooks.length;
      await withHook.release();
      hooks.clear();
      final macOS = await newAdapter(equalizer: _eq(), replayGainFilter: false);
      expect(macOS, isNotNull);
      expect(
        registered - hooks.length,
        1,
        reason: 'only the filter hook differs between the two',
      );
    });

    test('a clipping source seeds the level of its child', () async {
      final mpv = await newAdapter(equalizer: _eq());
      const c = 'https://music.example.invalid/c';
      await mpv.concatenatingInsertAll(
        ConcatenatingInsertAllRequest(
          id: 'queue',
          index: 2,
          children: [
            ClippingAudioSourceMessage(
              id: 'clip',
              child: ProgressiveAudioSourceMessage(
                id: c,
                uri: c,
                headers: null,
                replayGainDb: -7,
              ),
              start: const Duration(seconds: 10),
              end: const Duration(seconds: 70),
            ),
          ],
          shuffleOrder: const [0, 1, 2],
        ),
      );
      expect(mpv.replayGainFiltersForLoad(c), startsWith('$_rg-7.000dB'));
    });

    test('a new load drops the levels of the old queue', () async {
      final mpv = await newAdapter(equalizer: _eq());
      await mpv.load(queue({_b: 2}));
      expect(mpv.replayGainFiltersForLoad(_a), startsWith('${_rg}0.000dB'));
      expect(mpv.replayGainFiltersForLoad(_b), startsWith('${_rg}2.000dB'));
    });

    test(
      'a live push between load and the hook leaves the playing file',
      () async {
        final mpv = await newAdapter(equalizer: _eq());
        mpv.replayGainFiltersForLoad(_a);
        await mpv.load(queue({_b: 2}));
        sync.clear();
        await mpv.setReplayGainLevels(
          SetReplayGainLevelsRequest(byUri: const {_b: 5}, live: true),
        );
        expect(
          sync,
          isEmpty,
          reason: 'a still playing A must not step to 0 dB',
        );
        expect(mpv.replayGainFiltersForLoad(_b), startsWith('${_rg}5.000dB'));
      },
    );
  });

  group('without the EQ pipeline at 1x', () {
    test('the chain is the ReplayGain stage alone', () async {
      final mpv = await newAdapter();
      expect(mpv.replayGainFiltersForLoad(_a), '$_rg-9.000dB:precision=float]');
      await mpv.setSpeed(SetSpeedRequest(speed: 1.25));
      await mpv.setSpeed(SetSpeedRequest(speed: 1));
      expect(properties['af'], '$_rg-9.000dB:precision=float]');
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: -4}, live: true),
      );
      expect(sync.last, 'af=$_rg-4.000dB:precision=float]');
    });

    test('a pitch change brings the tempo stage back', () async {
      final mpv = await newAdapter();
      mpv.replayGainFiltersForLoad(_a);
      await mpv.setPitch(SetPitchRequest(pitch: 1.1));
      expect(properties['af'], contains('@navis_tempo:scaletempo:scale='));
    });
  });

  group('macOS (the filter stage is off)', () {
    test('no ReplayGain stage is ever written to af', () async {
      final mpv = await newAdapter(equalizer: _eq(), replayGainFilter: false);
      // A file is loaded, so a live push would have something to move.
      mpv.replayGainFiltersForLoad(_a);
      sync.clear();
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: -4}, live: true),
      );
      expect(sync, isEmpty);
      await mpv.setEqualizer(_eq(enabled: true));
      await mpv.setSpeed(SetSpeedRequest(speed: 1.25));
      expect(properties['af'], isNot(contains('navis_rg')));
      expect(properties['af'], contains('@navis_tempo'));
    });

    test('speed without the EQ pipeline is media_kit own setter', () async {
      when(() => player.setRate(any())).thenAnswer((_) async {});
      final mpv = await newAdapter(replayGainFilter: false);
      await mpv.setSpeed(SetSpeedRequest(speed: 1.25));
      verify(() => player.setRate(1.25)).called(1);
      expect(properties['af'], isNull);
    });
  });

  group('audio edits (what the second review mutations delete)', () {
    test('the next file loads with the edited speed, pitch and EQ', () async {
      final mpv = await newAdapter(equalizer: _eq(), sampleRate: 44100);
      await pumpEventQueue();
      await mpv.setSpeed(SetSpeedRequest(speed: 1.25));
      await mpv.setEqualizer(
        EqualizerConfigurationMessage(
          enabled: true,
          preampDb: -1,
          autoHeadroom: false,
          filters: const [
            EqualizerFilterMessage(
              type: 'peaking',
              frequencyHz: 1000,
              gainDb: 3,
              q: 1,
              enabled: true,
            ),
          ],
        ),
      );
      final next = mpv.replayGainFiltersForLoad(_b);
      expect(next, startsWith('${_rg}0.000dB'));
      expect(next, contains('scale=1.25'));
      expect(next, contains('@navis_eq:lavfi=['));
    });

    test('a failed edit rolls back to a chain with the level', () async {
      final mpv = await newAdapter(equalizer: _eq());
      mpv.replayGainFiltersForLoad(_a);
      var failed = false;
      when(() => native.setProperty('af', any())).thenAnswer((call) async {
        if (!failed) {
          failed = true;
          throw StateError('mpv rejected the chain');
        }
        properties['af'] = '${call.positionalArguments[1]}';
      });
      await expectLater(
        mpv.setEqualizer(_eq(enabled: true)),
        throwsA(isA<StateError>()),
      );
      expect(failed, isTrue);
      expect(properties['af'], startsWith('$_rg-9.000dB'));
    });
  });

  group('updates', () {
    test('a live update commands the filter, then writes af', () async {
      final mpv = await newAdapter(equalizer: _eq());
      mpv.replayGainFiltersForLoad(_a);
      sync.clear();
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: -4}, live: true),
      );
      expect(sync, hasLength(2));
      expect(sync[0], 'af-command navis_rg volume -4.000dB volume');
      expect(sync[1], startsWith('af=$_rg-4.000dB:precision=float],@navis'));
    });

    test('a failed af-command still writes af', () async {
      final mpv = await newAdapter(equalizer: _eq(), commandOk: false);
      mpv.replayGainFiltersForLoad(_a);
      sync.clear();
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: -4}, live: true),
      );
      expect(sync, hasLength(2));
      expect(sync[1], startsWith('af=$_rg-4.000dB'));
    });

    test('a non-live update leaves the playing file alone', () async {
      final mpv = await newAdapter(equalizer: _eq());
      mpv.replayGainFiltersForLoad(_a);
      sync.clear();
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: -4, _b: -2}),
      );
      expect(sync, isEmpty);
      // The EQ rebuild still carries the frozen -9, not the pushed -4.
      await mpv.setEqualizer(_eq());
      expect(properties['af'], startsWith('$_rg-9.000dB'));
      // The next start of the entry gets the new value.
      expect(mpv.replayGainFiltersForLoad(_b), startsWith('$_rg-2.000dB'));
    });

    test('an EQ edit keeps the level and the label first', () async {
      final mpv = await newAdapter(equalizer: _eq());
      mpv.replayGainFiltersForLoad(_a);
      await mpv.setEqualizer(_eq(enabled: true));
      expect(properties['af'], startsWith('$_rg-9.000dB'));
    });

    test('a live update before a level is known changes no file', () async {
      final mpv = await newAdapter(equalizer: _eq());
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: -4}, live: true),
      );
      expect(sync, isEmpty, reason: 'no file has loaded yet');
    });
  });
}
