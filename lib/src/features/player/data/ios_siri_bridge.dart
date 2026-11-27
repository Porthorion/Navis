import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/siri_play_request.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Answers Siri "Play `X` in Navis" (`INPlayMediaIntent`, #530) from the iOS
/// runner and keeps Siri's vocabulary (artists, playlists) current.
///
/// Native -> Dart: `status` -> `ready | signedOut | unavailable` (cheap, no
/// search); `playMedia` (`mediaType`, `mediaName`, `artistName`, `albumName`,
/// `genreName`, `deferred`) -> `playing | slow | notFound | offline |
/// signedOut | notReady`. `deferred: "1"` marks a cold-launch intent that
/// native replays once Dart is up: nobody is waiting on Siri, so it gets a
/// long prepare budget and no overall deadline. A normal request answers
/// `slow` when the search outlives [searchDeadline] (the load keeps running).
/// Dart -> native: `ready` (handler installed; native flushes a cold-launch
/// intent) and `setVocabulary` (`artists`, `playlists`; empty lists clear).
///
/// The search is [NavisPlaybackHandler.playFromVoiceSearch], the same one
/// Android Auto's voice search uses. Nothing throws across the channel.
class IosSiriBridge {
  new({
    required this.readPhase,
    required this.phases,
    required this.awaitHandler,
    required this.canStream,
    required this.hasDownloadedSongs,
    required this.artistNames,
    required this.playlistNames,
    required this.vocabularyChanges,
    this.readyBudget = const Duration(seconds: 8),
    this.deferredBudget = const Duration(seconds: 30),
    this.searchDeadline = const Duration(seconds: 9),
    this.vocabularyDebounce = const Duration(seconds: 2),
    this._channel = const MethodChannel(channelName),
  }) {
    _channel.setMethodCallHandler(_onCall);
    _subscriptions = [
      phases.listen((_) => _scheduleVocabulary(immediate: true)),
      vocabularyChanges.listen((_) => _scheduleVocabulary()),
    ];
    unawaited(_invoke('ready'));
    _scheduleVocabulary(immediate: true);
  }

  static const String channelName = 'com.navis.app/siri';

  final SessionRoutePhase Function() readPhase;

  /// A broadcast stream of session phase changes.
  final Stream<SessionRoutePhase> phases;
  final Future<NavisPlaybackHandler?> Function(Duration timeout) awaitHandler;
  final bool Function() canStream;
  final Future<bool> Function() hasDownloadedSongs;
  final Future<List<String>> Function() artistNames;
  final Future<List<String>> Function() playlistNames;

  /// Fires when playlists change or a library sync completes.
  final Stream<void> vocabularyChanges;

  /// How long `playMedia` waits, in total, for the session and the handler.
  final Duration readyBudget;

  /// The same wait for a `deferred` (cold-launch) request.
  final Duration deferredBudget;

  /// One deadline, from receipt, over prepare and the search of a normal
  /// request; Siri's own timeout is longer than this.
  final Duration searchDeadline;
  final Duration vocabularyDebounce;
  final MethodChannel _channel;
  late final List<StreamSubscription<Object?>> _subscriptions;
  Timer? _vocabularyTimer;
  Map<String, List<String>>? _lastVocabulary;
  var _disposed = false;

  Future<void> dispose() async {
    _disposed = true;
    _vocabularyTimer?.cancel();
    _channel.setMethodCallHandler(null);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'status':
        return await _status();
      case 'playMedia':
        return await _playMedia(call.arguments);
    }
    throw MissingPluginException();
  }

  Future<String> _status() async {
    try {
      if (readPhase() == SessionRoutePhase.unauthenticated) return 'signedOut';
      if (!canStream() && !await hasDownloadedSongs()) return 'unavailable';
    } on Object catch (error) {
      AppLogger.warning('Siri status failed: $error');
    }
    // Loading counts as ready; playMedia decides.
    return 'ready';
  }

  Future<String> _playMedia(Object? arguments) async {
    final args = arguments is Map
        ? arguments.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    final deferred = args['deferred'] == '1';
    final search = _search(args, deferred ? deferredBudget : readyBudget);
    if (deferred) return await search;
    return await search.timeout(searchDeadline, onTimeout: () => 'slow');
  }

  /// Never throws; keeps running after a `slow` reply.
  Future<String> _search(Map<Object?, Object?> args, Duration budget) async {
    try {
      final request = siriPlayMediaRequest(args);
      final prepared = await _prepare(budget).timeout(budget);
      if (prepared is! NavisPlaybackHandler) return prepared as String;
      AppLogger.info('Siri playMedia query="${request.query}"');
      if (await prepared.playFromVoiceSearch(request.query, request.extras)) {
        return 'playing';
      }
      return canStream() ? 'notFound' : 'offline';
    } on TimeoutException {
      return 'notReady';
    } on Object catch (error) {
      AppLogger.warning('Siri playMedia failed: $error');
      return 'notFound';
    }
  }

  /// The handler, or the status string to answer instead.
  Future<Object> _prepare(Duration budget) async {
    var phase = readPhase();
    if (phase == SessionRoutePhase.loading) {
      // `take(1)` cancels the listener on a result, a timeout or an error.
      final next = await phases
          .where((p) => p != SessionRoutePhase.loading)
          .timeout(budget)
          .take(1)
          .toList();
      if (next.isEmpty) return 'notReady'; // the phase stream closed
      phase = next.single;
    }
    switch (phase) {
      case SessionRoutePhase.unauthenticated:
        return 'signedOut';
      case SessionRoutePhase.initialSyncRequired:
        return 'notReady';
      case SessionRoutePhase.loading:
      case SessionRoutePhase.ready:
        break;
    }
    return await awaitHandler(budget) ?? 'notReady';
  }

  void _scheduleVocabulary({bool immediate = false}) {
    if (_disposed) return;
    _vocabularyTimer?.cancel();
    _vocabularyTimer = Timer(
      immediate ? Duration.zero : vocabularyDebounce,
      () => unawaited(_pushVocabulary()),
    );
  }

  Future<void> _pushVocabulary() async {
    try {
      final Map<String, List<String>> vocabulary;
      switch (readPhase()) {
        case SessionRoutePhase.ready:
          vocabulary = {
            'artists': _unique(await artistNames()),
            'playlists': _unique(await playlistNames()),
          };
        case SessionRoutePhase.unauthenticated:
          vocabulary = {'artists': <String>[], 'playlists': <String>[]};
        case SessionRoutePhase.loading:
        case SessionRoutePhase.initialSyncRequired:
          return;
      }
      if (_disposed || mapEquals(vocabulary, _lastVocabulary)) return;
      if (await _invoke('setVocabulary', vocabulary)) {
        _lastVocabulary = vocabulary;
      }
    } on Object catch (error) {
      AppLogger.warning('Siri vocabulary update failed: $error');
    }
  }

  List<String> _unique(Iterable<String> names) => [
    ...{
      for (final name in names)
        if (name.trim().isNotEmpty) name.trim(),
    },
  ];

  Future<bool> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
      return true;
    } on Object catch (error) {
      AppLogger.warning('Siri "$method" failed: $error');
      return false;
    }
  }
}
