import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/player/data/ios_siri_bridge.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';

import '../../../../helpers/fake_playback_handler.dart';

class _Handler extends InertPlaybackHandler {
  bool result = true;

  /// When set, the search waits for it.
  Completer<void>? gate;
  final queries = <(String, Map<String, dynamic>?)>[];

  @override
  Future<bool> playFromVoiceSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    queries.add((query, extras));
    await gate?.future;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(IosSiriBridge.channelName);
  const codec = StandardMethodCodec();

  late List<MethodCall> toNative;
  late SessionRoutePhase phase;
  late StreamController<SessionRoutePhase> phases;
  late StreamController<void> changes;
  late _Handler handler;
  late Completer<NavisPlaybackHandler?> handlerArrives;
  late bool online;
  late bool downloads;
  late List<String> artists;
  late List<String> playlists;
  late IosSiriBridge bridge;

  IosSiriBridge build({Stream<SessionRoutePhase>? phaseStream}) =>
      IosSiriBridge(
        channel: channel,
        readPhase: () => phase,
        phases: phaseStream ?? phases.stream,
        awaitHandler: (_) => handlerArrives.future,
        canStream: () => online,
        hasDownloadedSongs: () async => downloads,
        artistNames: () async => artists,
        playlistNames: () async => playlists,
        vocabularyChanges: changes.stream,
        readyBudget: const Duration(milliseconds: 100),
        deferredBudget: const Duration(milliseconds: 600),
        searchDeadline: const Duration(milliseconds: 250),
        vocabularyDebounce: const Duration(milliseconds: 20),
      );

  Future<Object?> native(String method, [Object? arguments]) async {
    final reply = Completer<ByteData?>();
    unawaited(
      messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall(method, arguments)),
        reply.complete,
      ),
    );
    return codec.decodeEnvelope((await reply.future)!);
  }

  Future<void> settle(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  List<MethodCall> vocab() =>
      toNative.where((c) => c.method == 'setVocabulary').toList();

  setUp(() {
    toNative = [];
    phase = SessionRoutePhase.ready;
    phases = StreamController<SessionRoutePhase>.broadcast();
    changes = StreamController<void>.broadcast();
    handler = _Handler();
    handlerArrives = Completer()..complete(handler);
    online = true;
    downloads = false;
    artists = ['Radiohead', 'Bjork'];
    playlists = ['Road trip'];
    messenger.setMockMethodCallHandler(channel, (call) async {
      toNative.add(call);
      return null;
    });
  });

  tearDown(() async {
    await bridge.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    await phases.close();
    await changes.close();
  });

  test('sends ready when created', () async {
    bridge = build();
    await settle(() => toNative.any((c) => c.method == 'ready'));
    expect(toNative.map((c) => c.method), contains('ready'));
  });

  group('playMedia', () {
    const args = {'mediaType': 'artist', 'mediaName': 'Radiohead'};

    test('signed out answers signedOut', () async {
      phase = SessionRoutePhase.unauthenticated;
      bridge = build();
      expect(await native('playMedia', args), 'signedOut');
      expect(handler.queries, isEmpty);
    });

    test('initial sync required answers notReady', () async {
      phase = SessionRoutePhase.initialSyncRequired;
      bridge = build();
      expect(await native('playMedia', args), 'notReady');
    });

    test('a cold launch waits for loading to finish, then plays', () async {
      phase = SessionRoutePhase.loading;
      bridge = build();
      final reply = native('playMedia', args);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      phase = SessionRoutePhase.ready;
      phases.add(SessionRoutePhase.ready);
      expect(await reply, 'playing');
      expect(handler.queries.single.$1, 'Radiohead');
      expect(handler.queries.single.$2, isNotEmpty);
    });

    test(
      'loading that never ends answers notReady within the budget',
      () async {
        phase = SessionRoutePhase.loading;
        bridge = build();
        expect(await native('playMedia', args), 'notReady');
      },
    );

    test('a timed-out wait cancels its phase listener', () async {
      var listens = 0;
      var cancels = 0;
      phase = SessionRoutePhase.loading;
      bridge = build(
        phaseStream: Stream<SessionRoutePhase>.multi((c) {
          listens++;
          final sub = phases.stream.listen(c.add);
          c.onCancel = () {
            cancels++;
            return sub.cancel();
          };
        }, isBroadcast: true),
      );
      await settle(() => listens > 0);
      final bridgeListeners = listens;
      expect(await native('playMedia', args), 'notReady');
      expect(listens, bridgeListeners + 1);
      expect(cancels, 1); // only the playMedia wait; the bridge's stays
    });

    test('a closed phase stream answers notReady', () async {
      phase = SessionRoutePhase.loading;
      bridge = build();
      final reply = native('playMedia', args);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await phases.close();
      expect(await reply, 'notReady');
    });

    test('a search past the deadline answers slow and keeps loading', () async {
      handler.gate = Completer();
      bridge = build();
      expect(await native('playMedia', args), 'slow');
      expect(handler.queries, hasLength(1));
      handler.gate!.complete();
    });

    test('the deadline covers prepare as well as the search', () async {
      handler.gate = Completer();
      handlerArrives = Completer();
      bridge = build();
      final reply = native('playMedia', args);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      handlerArrives.complete(handler); // inside the 100 ms prepare budget
      expect(await reply, 'slow'); // 250 ms from receipt, not from the handler
      handler.gate!.complete();
    });

    test('a deferred request waits past the normal budget and plays', () async {
      handlerArrives = Completer();
      bridge = build();
      final reply = native('playMedia', {...args, 'deferred': '1'});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      handlerArrives.complete(handler);
      expect(await reply, 'playing');
      expect(handler.queries.single.$1, 'Radiohead');
    });

    test('a deferred search has no overall deadline', () async {
      handler.gate = Completer();
      bridge = build();
      final reply = native('playMedia', {'deferred': '1', ...args});
      await Future<void>.delayed(const Duration(milliseconds: 400));
      handler.gate!.complete();
      expect(await reply, 'playing');
    });

    test('a deferred request still gives up after its own budget', () async {
      handlerArrives = Completer();
      bridge = build();
      expect(await native('playMedia', {...args, 'deferred': '1'}), 'notReady');
    });

    test('a handler that never arrives answers notReady', () async {
      handlerArrives = Completer();
      bridge = build();
      expect(await native('playMedia', args), 'notReady');
      expect(handler.queries, isEmpty);
    });

    test('a null handler answers notReady', () async {
      handlerArrives = Completer()..complete(null);
      bridge = build();
      expect(await native('playMedia', args), 'notReady');
    });

    test('nothing found while offline answers offline', () async {
      handler.result = false;
      online = false;
      bridge = build();
      expect(await native('playMedia', args), 'offline');
    });

    test('nothing found while online answers notFound', () async {
      handler.result = false;
      bridge = build();
      expect(await native('playMedia', args), 'notFound');
    });

    test('a thrown error answers notFound, never across the channel', () async {
      handlerArrives = Completer()..completeError(StateError('boom'));
      bridge = build();
      expect(await native('playMedia', args), 'notFound');
    });

    test('the deferred flag is not a media field', () async {
      bridge = build();
      expect(await native('playMedia', {'deferred': '1'}), 'playing');
      expect(handler.queries.single.$1, isEmpty);
      expect(handler.queries.single.$2, isEmpty);
    });

    test(
      'an empty request still reaches the handler (instant radio)',
      () async {
        bridge = build();
        expect(await native('playMedia', <String, String>{}), 'playing');
        expect(handler.queries.single.$1, isEmpty);
      },
    );
  });

  group('status', () {
    test('signed out', () async {
      phase = SessionRoutePhase.unauthenticated;
      bridge = build();
      expect(await native('status'), 'signedOut');
    });

    test('offline with downloads is ready', () async {
      online = false;
      downloads = true;
      bridge = build();
      expect(await native('status'), 'ready');
    });

    test('offline without downloads is unavailable', () async {
      online = false;
      bridge = build();
      expect(await native('status'), 'unavailable');
    });

    test('loading counts as ready', () async {
      phase = SessionRoutePhase.loading;
      bridge = build();
      expect(await native('status'), 'ready');
    });
  });

  group('vocabulary', () {
    test('is pushed when the library is ready, deduplicated', () async {
      artists = ['Radiohead', ' Radiohead ', 'Bjork', ''];
      bridge = build();
      await settle(() => vocab().isNotEmpty);
      expect(vocab().single.arguments, {
        'artists': ['Radiohead', 'Bjork'],
        'playlists': ['Road trip'],
      });
    });

    test('is pushed when the phase becomes ready', () async {
      phase = SessionRoutePhase.loading;
      bridge = build();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(vocab(), isEmpty);
      phase = SessionRoutePhase.ready;
      phases.add(SessionRoutePhase.ready);
      await settle(() => vocab().isNotEmpty);
      expect(vocab(), hasLength(1));
    });

    test('is cleared on sign-out', () async {
      bridge = build();
      await settle(() => vocab().isNotEmpty);
      phase = SessionRoutePhase.unauthenticated;
      phases.add(SessionRoutePhase.unauthenticated);
      await settle(() => vocab().length == 2);
      expect(vocab().last.arguments, {
        'artists': <String>[],
        'playlists': <String>[],
      });
    });

    test(
      'is re-pushed, debounced, when playlists or the library change',
      () async {
        bridge = build();
        await settle(() => vocab().isNotEmpty);
        playlists = ['Road trip', 'Focus'];
        changes
          ..add(null)
          ..add(null);
        await settle(() => vocab().length == 2);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(vocab(), hasLength(2));
        expect((vocab().last.arguments as Map)['playlists'], [
          'Road trip',
          'Focus',
        ]);
      },
    );
  });
}
