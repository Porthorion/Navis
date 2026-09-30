import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

/// Presents playback to the operating system in real listening time.
///
/// Navis keeps positions and durations in track time and reports the playback
/// speed separately, which is what the app, lyrics and seeking need. Bluetooth
/// AVRCP has no playback-rate field, and many car, headphone and lock-screen
/// displays tick at 1× between updates, so at 1.5× they drift and show the
/// track's full length. This adapter sits between audio_service and the real
/// handler and publishes positions and durations divided by the speed, with a
/// reported speed of 1×, so every external display stays correct. Seeks
/// requested by the system arrive in that real-time scale and are converted
/// back to track time. Everything else is forwarded unchanged.
class RealTimeProjectionAudioHandler extends CompositeAudioHandler {
  RealTimeProjectionAudioHandler(this.inner) : super(inner) {
    _subscriptions
      ..add(
        inner.playbackState.listen((state) {
          _playbackState.add(projectPlaybackStateToRealTime(state));
          _publishMediaItem();
        }),
      )
      ..add(inner.mediaItem.listen((_) => _publishMediaItem()));
  }

  /// The handler the app talks to directly, in track time.
  final AudioHandler inner;

  final BehaviorSubject<PlaybackState> _playbackState =
      BehaviorSubject<PlaybackState>();
  final BehaviorSubject<MediaItem?> _mediaItem = BehaviorSubject<MediaItem?>();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  MediaItem? _lastSourceItem;
  double? _lastSpeed;

  double get _speed => inner.playbackState.valueOrNull?.speed ?? 1.0;

  /// Republishes metadata only when the item or the speed changes; playback
  /// state events are frequent, and each metadata update makes the system
  /// refresh its media controls.
  void _publishMediaItem() {
    final source = inner.mediaItem.valueOrNull;
    final speed = _speed;
    if (_mediaItem.hasValue &&
        identical(source, _lastSourceItem) &&
        speed == _lastSpeed) {
      return;
    }
    _lastSourceItem = source;
    _lastSpeed = speed;
    _mediaItem.add(projectMediaItemToRealTime(source, speed));
  }

  @override
  ValueStream<PlaybackState> get playbackState => _playbackState;

  @override
  ValueStream<MediaItem?> get mediaItem => _mediaItem;

  @override
  // Calling super would forward the unconverted real-time position.
  // ignore: must_call_super
  Future<void> seek(Duration position) =>
      inner.seek(realTimeToTrackPosition(position, _speed));
}

/// Speeds this close to 1× are treated as 1× so ordinary playback is published
/// exactly as before.
bool _isNormalSpeed(double speed) =>
    !speed.isFinite || speed <= 0 || (speed - 1.0).abs() < 0.0005;

Duration _divide(Duration value, double speed) =>
    Duration(microseconds: (value.inMicroseconds / speed).round());

@visibleForTesting
PlaybackState projectPlaybackStateToRealTime(PlaybackState state) {
  if (_isNormalSpeed(state.speed)) return state;
  return state.copyWith(
    updatePosition: _divide(state.updatePosition, state.speed),
    bufferedPosition: _divide(state.bufferedPosition, state.speed),
    speed: 1.0,
  );
}

@visibleForTesting
MediaItem? projectMediaItemToRealTime(MediaItem? item, double speed) {
  final duration = item?.duration;
  if (item == null || duration == null || _isNormalSpeed(speed)) return item;
  return item.copyWith(duration: _divide(duration, speed));
}

@visibleForTesting
Duration realTimeToTrackPosition(Duration position, double speed) {
  if (_isNormalSpeed(speed)) return position;
  return Duration(microseconds: (position.inMicroseconds * speed).round());
}
