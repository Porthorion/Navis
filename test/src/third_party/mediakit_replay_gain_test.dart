import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
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
    // False skips the probe; null runs it against [accept].
    bool? limiterSupported = false,
    bool Function(String name, String value)? accept,
    // False leaves the probe to the first load.
    bool readyFirst = true,
    // False leaves the probe unanswered when [readyFirst] is false too.
    bool loadQueue = true,
    String id = 'test',
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
      id,
      player: player,
      equalizer: equalizer,
      icyPropertySource: _Properties(),
      replayGainFilter: replayGainFilter,
      limiterSupported: limiterSupported,
      commandSync: (line) {
        sync.add(line);
        return commandOk;
      },
      setPropertySync: (name, value) {
        sync.add('$name=$value');
        return accept?.call(name, value) ?? true;
      },
    );
    adapter = created;
    if (readyFirst) await created.ready();
    if (loadQueue) await created.load(queue(levels));
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

  group('one file at two queue positions', () {
    ProgressiveAudioSourceMessage entry(String id, double db) =>
        ProgressiveAudioSourceMessage(
          id: id,
          uri: _a,
          headers: null,
          replayGainDb: db,
        );

    Future<MediaKitPlayer> twice() async {
      final mpv = await newAdapter(equalizer: _eq());
      await mpv.load(
        LoadRequest(
          audioSourceMessage: ConcatenatingAudioSourceMessage(
            id: 'queue',
            children: [entry('first', -9), entry('second', -3)],
            useLazyPreparation: false,
            shuffleOrder: const [0, 1],
          ),
          initialIndex: 0,
          initialPosition: null,
        ),
      );
      return mpv;
    }

    String level(MediaKitPlayer mpv, int index) =>
        mpv.replayGainFiltersForLoad(_a, index: index);

    test('each entry plays at its own level', () async {
      final mpv = await twice();
      expect(level(mpv, 0), startsWith('$_rg-9.000dB'));
      expect(level(mpv, 1), startsWith('$_rg-3.000dB'));
      expect(level(mpv, 0), startsWith('$_rg-9.000dB'));
    });

    test(
      'an index that names another file falls back to the URI level',
      () async {
        final mpv = await newAdapter(equalizer: _eq());
        await mpv.load(
          LoadRequest(
            audioSourceMessage: ConcatenatingAudioSourceMessage(
              id: 'queue',
              children: [
                ProgressiveAudioSourceMessage(
                  id: 'e0',
                  uri: _a,
                  headers: null,
                  replayGainDb: -9,
                ),
                ProgressiveAudioSourceMessage(
                  id: 'e1',
                  uri: _b,
                  headers: null,
                  replayGainDb: 4,
                ),
              ],
              useLazyPreparation: false,
              shuffleOrder: const [0, 1],
            ),
            initialIndex: 0,
            initialPosition: null,
          ),
        );
        // The hook read a stale index 0 while file b loads.
        expect(
          mpv.replayGainFiltersForLoad(_b, index: 0),
          startsWith('${_rg}4.000dB'),
        );
      },
    );

    test('a push moves the entry it names, by id', () async {
      final mpv = await twice();
      level(mpv, 1);
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(
          byId: const {'first': -1, 'second': -5},
          byUri: const {_a: -5},
          live: true,
        ),
      );
      expect(sync, contains(startsWith('af=$_rg-5.000dB')));
      expect(level(mpv, 0), startsWith('$_rg-1.000dB'));
      expect(level(mpv, 1), startsWith('$_rg-5.000dB'));
    });

    test('inserts, moves and removals keep entries with their level', () async {
      final mpv = await twice();
      // media_kit's playlist, which the mock does not keep.
      final medias = [Media(_a), Media(_a)];
      when(() => player.state)
          .thenAnswer((_) => PlayerState(playlist: Playlist(medias)));
      when(() => player.add(any())).thenAnswer((call) async {
        medias.add(call.positionalArguments[0] as Media);
      });
      when(() => player.move(any(), any())).thenAnswer((call) async {
        final from = call.positionalArguments[0] as int;
        final to = call.positionalArguments[1] as int;
        medias.insert(to > from ? to - 1 : to, medias.removeAt(from));
      });
      when(() => player.remove(any())).thenAnswer((call) async {
        medias.removeAt(call.positionalArguments[0] as int);
      });
      await mpv.concatenatingInsertAll(
        ConcatenatingInsertAllRequest(
          id: 'queue',
          index: 1,
          children: [entry('third', 4)],
          shuffleOrder: const [0, 1, 2],
        ),
      );
      expect(level(mpv, 1), startsWith('${_rg}4.000dB'));
      expect(level(mpv, 2), startsWith('$_rg-3.000dB'));
      await mpv.concatenatingMove(
        ConcatenatingMoveRequest(
          id: 'queue',
          currentIndex: 2,
          newIndex: 0,
          shuffleOrder: const [0, 1, 2],
        ),
      );
      expect(level(mpv, 0), startsWith('$_rg-3.000dB'));
      expect(level(mpv, 1), startsWith('$_rg-9.000dB'));
      await mpv.concatenatingRemoveRange(
        ConcatenatingRemoveRangeRequest(
          id: 'queue',
          startIndex: 0,
          endIndex: 1,
          shuffleOrder: const [0, 1],
        ),
      );
      expect(level(mpv, 0), startsWith('$_rg-9.000dB'));
      expect(level(mpv, 1), startsWith('${_rg}4.000dB'));
    });
  });

  group('the load path (what the review mutations delete)', () {
    test('the adapter registers the ReplayGain on_load hook', () async {
      final withHook = await newAdapter(equalizer: _eq());
      final registered = hooks.length;
      await withHook.release();
      hooks.clear();
      final withoutFilter = await newAdapter(
        equalizer: _eq(),
        replayGainFilter: false,
      );
      expect(withoutFilter, isNotNull);
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

  group('without the filter stage (replayGainFilter: false)', () {
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

  group('the limiter stage', () {
    const limiter =
        '@navis_lim:lavfi=[alimiter=limit=0.891:level=0:attack=5:release=100:latency=1]';
    EqualizerChain plain() => EqualizerChain.compile(_eq(), speed: 1, pitch: 1);

    test('the string is byte-constant and level=0, latency=1 stay', () {
      // A typo here is accepted by mpv and mutes every file at audio init.
      expect(EqualizerChain.limiterStage, limiter);
    });

    test('a cut or unity never gets it, a boost gets it last', () {
      for (final db in [-6.0, 0.0]) {
        expect(
          plain().withReplayGain(db, limiterSupported: true),
          plain().withReplayGain(db),
        );
      }
      expect(
        plain().withReplayGain(3, limiterSupported: true),
        '${plain().withReplayGain(3)},$limiter',
      );
      expect(plain().withReplayGain(3), isNot(contains('navis_lim')));
      expect(
        EqualizerChain(
          filters: '',
          state: const EqualizerStateMessage(enabled: false),
        ).withReplayGain(3, limiterSupported: true),
        '${_rg}3.000dB:precision=float],$limiter',
      );
    });

    test('it follows the EQ stage', () {
      final chain = EqualizerChain.compile(
        EqualizerConfigurationMessage(
          enabled: true,
          preampDb: 0,
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
      );
      final text = chain.withReplayGain(4, limiterSupported: true);
      expect(text.indexOf('@navis_eq'), lessThan(text.indexOf('@navis_lim')));
      expect(text, endsWith(limiter));
    });

    test('the probe is the wrapper form, then af is cleared again', () {
      final writes = <String>[];
      expect(
        EqualizerChain.probeLimiter((name, value) {
          writes.add('$name=$value');
          return true;
        }),
        isTrue,
      );
      expect(writes, ['af=@navis_probe:lavfi-alimiter', 'af=']);
      writes.clear();
      expect(
        EqualizerChain.probeLimiter((name, value) {
          writes.add('$name=$value');
          return value.isEmpty;
        }),
        isFalse,
      );
      expect(writes.last, 'af=');
    });

    test('the probe answers before the first load', () async {
      final yes = await newAdapter(limiterSupported: null);
      expect(sync.take(2), ['af=@navis_probe:lavfi-alimiter', 'af=']);
      expect(yes.limiterSupported, isTrue);
      await yes.release();
      adapter = null;
      sync.clear();
      final no = await newAdapter(
        limiterSupported: null,
        accept: (_, value) => !value.contains('probe'),
      );
      expect(no.limiterSupported, isFalse);
      // Never a limiter without the probe, however loud the file.
      expect(no.replayGainFiltersForLoad(_a), isNot(contains('navis_lim')));
      await no.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: 5}, live: true),
      );
      no.replayGainFiltersForLoad(_a);
      await no.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: 6}, live: true),
      );
      expect(sync.where((l) => l.contains('navis_lim')), isEmpty);
    });

    test('a load awaits the probe before it answers', () async {
      final mpv = await newAdapter(limiterSupported: null, readyFirst: false);
      expect(sync.take(2), ['af=@navis_probe:lavfi-alimiter', 'af=']);
      expect(mpv.limiterSupported, isTrue);
    });

    test('no probe without the filter stage', () async {
      await newAdapter(limiterSupported: null, replayGainFilter: false);
      expect(sync, isEmpty);
    });

    test('the on_load chain of a boosted file ends with it', () async {
      final mpv = await newAdapter(
        levels: const {_a: 6, _b: -2},
        limiterSupported: true,
      );
      expect(mpv.replayGainFiltersForLoad(_a), endsWith(limiter));
      expect(mpv.replayGainFiltersForLoad(_b), isNot(contains('navis_lim')));
    });

    test('a loud file after a quiet one is written with and without', () async {
      final mpv = await newAdapter(
        levels: const {_a: 6, _b: -2},
        limiterSupported: true,
      );
      expect(mpv.writeLoadChain(_a), isTrue);
      expect(sync.last, endsWith(limiter));
      expect(mpv.writeLoadChain(_b), isTrue);
      expect(sync.last, isNot(contains('navis_lim')));
    });

    test('an EQ edit under a boost keeps the limiter and verifies', () async {
      final mpv = await newAdapter(
        equalizer: _eq(),
        levels: const {_a: 6},
        limiterSupported: true,
        sampleRate: 44100,
      );
      mpv.replayGainFiltersForLoad(_a);
      // mpv reads the limiter graph back in its own quoting.
      when(() => native.getProperty('af')).thenAnswer(
        (_) async => properties['af']!.replaceFirst(
          '@navis_lim:lavfi=[',
          '@navis_lim:lavfi=graph=%99%',
        ),
      );
      await mpv.setEqualizer(
        EqualizerConfigurationMessage(
          enabled: true,
          preampDb: 0,
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
      expect(properties['af'], endsWith(limiter));
    });

    test('a level-only live update still commands, then writes', () async {
      final mpv = await newAdapter(
        levels: const {_a: 6},
        limiterSupported: true,
      );
      mpv.replayGainFiltersForLoad(_a);
      sync.clear();
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: 4}, live: true),
      );
      expect(sync, hasLength(2));
      expect(sync[0], 'af-command navis_rg volume 4.000dB volume');
      expect(sync[1], endsWith(limiter));
    });

    test('adding the limiter skips af-command and writes af once', () async {
      final mpv = await newAdapter(
        levels: const {_a: -3},
        limiterSupported: true,
      );
      mpv.replayGainFiltersForLoad(_a);
      sync.clear();
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: 5}, live: true),
      );
      expect(sync, hasLength(1));
      expect(sync.single, startsWith('af=${_rg}5.000dB'));
      expect(sync.single, endsWith(limiter));
    });

    test(
      'dropping the limiter (Loud to Normal) steps, then rewrites',
      () async {
        final mpv = await newAdapter(
          levels: const {_a: 5},
          limiterSupported: true,
        );
        mpv.replayGainFiltersForLoad(_a);
        sync.clear();
        await mpv.setReplayGainLevels(
          SetReplayGainLevelsRequest(byUri: const {_a: -2}, live: true),
        );
        expect(sync, hasLength(2));
        expect(sync[0], startsWith('af-command navis_rg volume -2.000dB'));
        expect(sync[1], isNot(contains('navis_lim')));
      },
    );

    test(
      'a rejected on_load write is retried at no boost, no limiter',
      () async {
        final mpv = await newAdapter(
          levels: const {_a: 6},
          limiterSupported: true,
          accept: (_, value) => !value.contains('navis_lim'),
        );
        sync.clear();
        expect(mpv.writeLoadChain(_a), isTrue);
        expect(sync, hasLength(2));
        expect(sync[0], endsWith(limiter));
        // The +6 dB was decided for a limited path: never unlimited.
        expect(sync[1], startsWith('af=${_rg}0.000dB'));
        expect(sync[1], isNot(contains('navis_lim')));
        expect(mpv.limiterSupported, isFalse);
        sync.clear();
        expect(mpv.writeLoadChain(_a), isTrue);
        expect(sync, hasLength(1), reason: 'not retried again: no limiter');
        expect(sync.single, startsWith('af=${_rg}0.000dB'));
        // Every later chain for the queued boost is clamped too.
        expect(mpv.replayGainFiltersForLoad(_a), startsWith('${_rg}0.000dB'));
        expect(mpv.replayGainFiltersForLoad(_a), isNot(contains('navis_lim')));
      },
    );

    test('a cut stays a cut after the limiter is rejected', () async {
      final mpv = await newAdapter(
        levels: const {_a: 6, _b: -2},
        limiterSupported: true,
        accept: (_, value) => !value.contains('navis_lim'),
      );
      expect(mpv.writeLoadChain(_a), isTrue);
      sync.clear();
      expect(mpv.writeLoadChain(_b), isTrue);
      expect(sync.single, startsWith('af=$_rg-2.000dB'));
    });

    test('a failure that is not the limiter keeps the limiter', () async {
      final mpv = await newAdapter(
        levels: const {_a: 6},
        limiterSupported: true,
        accept: (_, _) => false,
      );
      sync.clear();
      expect(mpv.writeLoadChain(_a), isFalse);
      expect(sync, hasLength(2));
      expect(mpv.limiterSupported, isTrue);
      expect(mpv.replayGainFiltersForLoad(_a), endsWith(limiter));
    });

    test('a rejected live write is retried without the limiter', () async {
      final mpv = await newAdapter(
        levels: const {_a: -3},
        limiterSupported: true,
        accept: (_, value) => !value.contains('navis_lim'),
      );
      mpv.replayGainFiltersForLoad(_a);
      sync.clear();
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: 5}, live: true),
      );
      expect(sync, hasLength(2));
      expect(sync[1], startsWith('af=${_rg}0.000dB'));
      expect(sync[1], isNot(contains('navis_lim')));
      expect(mpv.limiterSupported, isFalse);
      // A later live step is clamped too: af-command and af.
      sync.clear();
      await mpv.setReplayGainLevels(
        SetReplayGainLevelsRequest(byUri: const {_a: 6}, live: true),
      );
      expect(sync[0], 'af-command navis_rg volume 0.000dB volume');
      expect(sync[1], startsWith('af=${_rg}0.000dB'));
    });

    test(
      'a live boost whose af writes all fail never reaches af-command',
      () async {
        final mpv = await newAdapter(
          levels: const {_a: -3},
          limiterSupported: true,
          accept: (name, _) => name != 'af',
        );
        mpv.replayGainFiltersForLoad(_a);
        sync.clear();
        // mpv keeps the -3 dB chain without a limiter: current stays -3, so
        // the next push is again a limiter-adding one (af only), never a step.
        for (final db in [5.0, 6.0]) {
          await mpv.setReplayGainLevels(
            SetReplayGainLevelsRequest(byUri: {_a: db}, live: true),
          );
        }
        expect(sync.where((l) => l.startsWith('af-command')), isEmpty);
        expect(mpv.limiterSupported, isTrue);
      },
    );

    test('a rejected edit write is retried without the limiter', () async {
      final mpv = await newAdapter(
        equalizer: _eq(),
        levels: const {_a: 6},
        limiterSupported: true,
      );
      mpv.replayGainFiltersForLoad(_a);
      when(() => native.setProperty('af', any())).thenAnswer((call) async {
        final value = '${call.positionalArguments[1]}';
        if (!value.contains('navis_lim')) properties['af'] = value;
      });
      await mpv.setSpeed(SetSpeedRequest(speed: 1.25));
      expect(properties['af'], startsWith('${_rg}0.000dB'));
      expect(properties['af'], isNot(contains('navis_lim')));
      expect(mpv.limiterSupported, isFalse);
    });

    test('a failed edit retry never restores over a concurrent loss', () async {
      final mpv = await newAdapter(
        equalizer: _eq(),
        levels: const {_a: 6},
        limiterSupported: true,
        accept: (_, value) => !value.contains('navis_lim'),
      );
      mpv.replayGainFiltersForLoad(_a);
      // While the edit awaits mpv, the on_load hook finds the limiter
      // rejected. mpv then keeps the old chain, so the edit and its
      // unlimited retry both fail verification.
      var concurrent = false;
      when(() => native.setProperty('af', any())).thenAnswer((_) async {
        if (!concurrent) mpv.writeLoadChain(_a);
        concurrent = true;
      });
      await expectLater(
        mpv.setSpeed(SetSpeedRequest(speed: 1.25)),
        throwsStateError,
      );
      expect(mpv.limiterSupported, isFalse);
    });

    test('a failing edit that is not the limiter keeps it', () async {
      final mpv = await newAdapter(
        equalizer: _eq(),
        levels: const {_a: 6},
        limiterSupported: true,
      );
      mpv.replayGainFiltersForLoad(_a);
      when(() => native.setProperty('af', any())).thenAnswer((_) async {});
      await expectLater(
        mpv.setSpeed(SetSpeedRequest(speed: 1.25)),
        throwsStateError,
      );
      expect(mpv.limiterSupported, isTrue);
    });
  });

  group('JustAudioMediaKit.replayGainLimiterSupported', () {
    // Read per decision by the handler, never cached: false is the safe
    // answer (an under-boost) until every player is probed and has a limiter.
    final platform = JustAudioMediaKit();
    final before = JustAudioPlatform.instance;

    setUp(() => JustAudioPlatform.instance = platform);
    tearDown(() async {
      await platform.disposeAllPlayers(DisposeAllPlayersRequest());
      JustAudioPlatform.instance = before;
    });

    test('is false with no player', () {
      expect(JustAudioMediaKit.replayGainLimiterSupported, isFalse);
    });

    test('is false while the probe is pending, true once confirmed', () async {
      final mpv = await newAdapter(
        limiterSupported: true,
        readyFirst: false,
        loadQueue: false,
      );
      platform.debugRegisterPlayer(mpv);
      expect(JustAudioMediaKit.replayGainLimiterSupported, isFalse);
      await mpv.ready();
      expect(JustAudioMediaKit.replayGainLimiterSupported, isTrue);
    });

    test('needs every player: one without a limiter makes it false', () async {
      platform.debugRegisterPlayer(
        await newAdapter(limiterSupported: true, id: 'one'),
      );
      expect(JustAudioMediaKit.replayGainLimiterSupported, isTrue);
      platform.debugRegisterPlayer(
        await newAdapter(limiterSupported: false, id: 'two'),
      );
      expect(JustAudioMediaKit.replayGainLimiterSupported, isFalse);
    });

    test('goes false when a player loses its limiter', () async {
      final mpv = await newAdapter(
        levels: const {_a: 6},
        limiterSupported: true,
        accept: (_, value) => !value.contains('navis_lim'),
      );
      platform.debugRegisterPlayer(mpv);
      expect(JustAudioMediaKit.replayGainLimiterSupported, isTrue);
      mpv.writeLoadChain(_a);
      expect(JustAudioMediaKit.replayGainLimiterSupported, isFalse);
    });
  });
}
