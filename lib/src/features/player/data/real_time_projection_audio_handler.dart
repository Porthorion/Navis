import 'dart:async';
import 'dart:math' as math;

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
/// back to track time.
///
/// The system queue is a window of the app's queue around the current song
/// (see [queueWindowBefore] and [queueWindowAfter]). audio_service sends the
/// whole list over the platform channel on every change, which for a long or
/// growing queue blocked the UI thread; the window is republished only when
/// its songs change, and system queue indices are mapped back to the full
/// queue. Everything else is forwarded unchanged.
class RealTimeProjectionAudioHandler extends CompositeAudioHandler {
  RealTimeProjectionAudioHandler(this.inner) : super(inner) {
    _subscriptions
      ..add(
        inner.playbackState.listen((state) {
          _publishQueueWindow();
          _playbackState.add(
            _withWindowedQueueIndex(projectPlaybackStateToRealTime(state)),
          );
          _publishMediaItem();
        }),
      )
      ..add(inner.mediaItem.listen((_) => _publishMediaItem()))
      ..add(
        inner.queue.listen((_) {
          if (_publishQueueWindow()) {
            final state = inner.playbackState.valueOrNull;
            if (state != null) {
              _playbackState.add(
                _withWindowedQueueIndex(projectPlaybackStateToRealTime(state)),
              );
            }
          }
        }),
      );
  }

  /// Songs before the current one kept in the system queue.
  static const int queueWindowBefore = 20;

  /// Songs after the current one kept in the system queue.
  static const int queueWindowAfter = 80;

  /// The handler the app talks to directly, in track time.
  final AudioHandler inner;

  final BehaviorSubject<PlaybackState> _playbackState =
      BehaviorSubject<PlaybackState>();
  final BehaviorSubject<MediaItem?> _mediaItem = BehaviorSubject<MediaItem?>();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  final BehaviorSubject<List<MediaItem>> _queue =
      BehaviorSubject<List<MediaItem>>();
  int _queueWindowStart = 0;

  MediaItem? _lastSourceItem;
  double? _lastSpeed;

  /// Recomputes the system queue window. Returns whether it was republished.
  bool _publishQueueWindow() {
    final source = inner.queue.valueOrNull ?? const <MediaItem>[];
    final index = inner.playbackState.valueOrNull?.queueIndex;
    const size = queueWindowBefore + queueWindowAfter + 1;
    var start = _queueWindowStart;
    if (index == null || index < 0 || index >= source.length) {
      start = math.min(start, math.max(0, source.length - 1));
    } else if (index - start < queueWindowBefore ~/ 4 ||
        start + size - index < queueWindowAfter ~/ 4) {
      // Recentre only near the window's edges, so ordinary track changes
      // do not republish the queue.
      start = math.max(0, index - queueWindowBefore);
    }
    final end = math.min(source.length, start + size);
    start = math.max(0, math.min(start, end));
    final current = _queue.valueOrNull;
    if (current != null &&
        start == _queueWindowStart &&
        current.length == end - start) {
      var same = true;
      for (var i = 0; i < current.length; i++) {
        if (!identical(current[i], source[start + i])) {
          same = false;
          break;
        }
      }
      if (same) return false;
    }
    _queueWindowStart = start;
    _queue.add(List<MediaItem>.unmodifiable(source.sublist(start, end)));
    return true;
  }

  PlaybackState _withWindowedQueueIndex(PlaybackState state) {
    final index = state.queueIndex;
    if (index == null) return state;
    final windowed = index - _queueWindowStart;
    final length = _queue.valueOrNull?.length ?? 0;
    return state.copyWith(
      queueIndex: windowed >= 0 && windowed < length ? windowed : null,
    );
  }

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
  ValueStream<List<MediaItem>> get queue => _queue;

  @override
  // The system addresses its windowed queue; map to the full queue.
  // ignore: must_call_super
  Future<void> skipToQueueItem(int index) =>
      inner.skipToQueueItem(index + _queueWindowStart);

  @override
  // Calling super would forward the window-relative index.
  // ignore: must_call_super
  Future<void> removeQueueItemAt(int index) =>
      inner.removeQueueItemAt(index + _queueWindowStart);

  @override
  // Calling super would forward the window-relative index.
  // ignore: must_call_super
  Future<void> insertQueueItem(int index, MediaItem mediaItem) =>
      inner.insertQueueItem(index + _queueWindowStart, mediaItem);

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

/// Converts a track position to real listening time at [speed].
Duration trackToRealTimePosition(Duration position, double speed) =>
    _isNormalSpeed(speed) ? position : _divide(position, speed);

/// Converts a real listening time position back to track time at [speed].
Duration realTimeToTrackPosition(Duration position, double speed) {
  if (_isNormalSpeed(speed)) return position;
  return Duration(microseconds: (position.inMicroseconds * speed).round());
}
