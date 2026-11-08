import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/data/desktop_transport_actions.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Feeds the macOS Dock menu (`AppDelegate.applicationDockMenu`) and the
/// menu-bar Controls menu, and runs their Play/Pause, Next and Previous items
/// on [NavisPlaybackHandler].
///
/// Dart pushes `update` whenever the displayed state changes (identical
/// states are dropped); Swift sends `command` with an `action` when an item
/// is chosen. The native side keeps only the last pushed state.
class MacosDockMenuBridge {
  new({
    required this._handler,
    required this._localizations,
    this._channel = const MethodChannel(channelName),
  }) {
    _channel.setMethodCallHandler(_onCall);
    _subscriptions = [
      _handler.snapshotStream.listen((_) => unawaited(_push())),
      _handler.mediaItemStream.listen((_) => unawaited(_push())),
    ];
    unawaited(_push());
  }

  static const String channelName = 'com.navis.app/dock_menu';

  final NavisPlaybackHandler _handler;
  final AppLocalizations _localizations;
  final MethodChannel _channel;
  late final List<StreamSubscription<Object?>> _subscriptions;
  Map<String, Object?>? _lastPushed;

  Future<void> _push({bool cleared = false}) async {
    final item = cleared ? null : _handler.currentMediaItem;
    final playing = !cleared && _handler.snapshot.playing;
    final state = <String, Object?>{
      'hasItem': item != null,
      'title': item?.title ?? '',
      'artist': item?.artist ?? '',
      'playing': playing,
      'playPauseLabel': playing
          ? _localizations.nowPlayingPause
          : _localizations.nowPlayingPlay,
      'nextLabel': _localizations.nowPlayingNext,
      'previousLabel': _localizations.nowPlayingPrevious,
      'controlsMenuLabel': _localizations.macosMenuControls,
    };
    if (mapEquals(state, _lastPushed)) return;
    _lastPushed = state;
    try {
      await _channel.invokeMethod<void>('update', state);
    } on Object catch (error) {
      // The native menu is cosmetic; playback must not depend on it.
      AppLogger.warning('macOS Dock menu update failed: $error');
    }
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'command') throw MissingPluginException();
    final action = (call.arguments as Map<Object?, Object?>?)?['action'];
    final snapshot = _handler.snapshot;
    try {
      switch (action) {
        case 'playPause':
          await desktopPlayPause(_handler, snapshot);
        case 'next':
          await desktopNextTrack(_handler, snapshot);
        case 'previous':
          await desktopPreviousTrack(_handler, snapshot);
        default:
          AppLogger.warning('Unknown menu action: $action');
      }
    } on Object catch (error) {
      AppLogger.warning('macOS menu action "$action" failed: $error');
    }
  }

  /// Stops listening and empties the native menu, so it never outlives the
  /// handler it controlled.
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    await _push(cleared: true);
  }
}
