import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Owns one speculative GET, including the time before response headers arrive.
class SeekPreviewRequest {
  new(this._uri, {HttpClient? client, String? userAgent})
    : _client = client ?? HttpClient(),
      _userAgent = userAgent {
    if (userAgent != null) _client.userAgent = userAgent;
    _ready.future.ignore();
    unawaited(_open(_uri));
  }

  @visibleForTesting
  // ignore: experimental_member_use, reason: Inspect the adopted source's retry ownership in regression tests.
  static int retryCount(StreamAudioSource source) =>
      (source as _SeekPreviewAudioSource)._retries.length;

  static const _limit = 512 * 1024;
  final Uri _uri;
  final String? _userAgent;
  final HttpClient _client;
  final _ready = Completer<HttpClientResponse>();
  final _finished = Completer<void>();
  final _buffer = <List<int>>[];
  StreamSubscription<List<int>>? _subscription;
  StreamController<List<int>>? _output;
  int _bufferedBytes = 0;
  bool _cancelled = false;
  bool _done = false;
  Object? _error;
  StackTrace? _stack;

  /// Whether the response is still available for adoption.
  bool get usable => !_cancelled && _error == null;

  @visibleForTesting
  int get bufferedBytes => _bufferedBytes;

  Future<void> _open(Uri uri) async {
    try {
      final request = await _client.getUrl(uri);
      if (_cancelled) return;
      final response = await request.close();
      if (_cancelled) return;
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Seek preview HTTP ${response.statusCode}');
      }
      _ready.complete(response);
      // Split at the exact budget boundary; backpressure retains any remainder
      // in the input stream rather than copying it into the preview buffer.
      _subscription = response
          .asyncExpand<List<int>>((bytes) async* {
            var start = 0;
            while (start < bytes.length) {
              final room = _output == null
                  ? _limit - _bufferedBytes
                  : bytes.length;
              final end = math
                  .min(bytes.length, start + math.max(1, room))
                  .toInt();
              yield bytes.sublist(start, end);
              start = end;
            }
          })
          .listen(
            (bytes) {
              final output = _output;
              if (output != null) {
                output.add(bytes);
              } else {
                _buffer.add(bytes);
                _bufferedBytes += bytes.length;
                if (_bufferedBytes >= _limit) _subscription?.pause();
              }
            },
            onError: (Object error, StackTrace stack) {
              final failure = _withoutCredentials(error);
              _error = failure;
              _stack = stack;
              _finish();
              final output = _output;
              if (output != null) {
                output.addError(failure, stack);
                unawaited(output.close());
              }
            },
            onDone: () {
              _finish();
              if (_output case final output?) unawaited(output.close());
            },
            cancelOnError: true,
          );
    } on Object catch (error, stack) {
      if (_cancelled) return;
      final failure = _withoutCredentials(error);
      _error = failure;
      _stack = stack;
      _finish();
      if (!_ready.isCompleted) _ready.completeError(failure, stack);
    }
  }

  void _finish() {
    _done = true;
    _client.close(force: true);
    if (!_finished.isCompleted) _finished.complete();
  }

  // HttpException.uri can contain salted Subsonic authentication parameters.
  Object _withoutCredentials(Object error) =>
      error is HttpException ? HttpException(error.message) : error;

  /// Closes the socket before returning; no successor waits for HTTP cleanup.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _finish();
    unawaited(_subscription?.cancel());
    _subscription = null;
    _buffer.clear();
    _bufferedBytes = 0;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Seek preview cancelled'));
    }
    if (_output case final output?) unawaited(output.close());
  }

  // ignore: experimental_member_use, reason: Adopt the response through just_audio's existing proxy.
  StreamAudioSource asAudioSource({
    dynamic tag,
    Duration positionOffset = Duration.zero,
  }) => _SeekPreviewAudioSource(this, tag: tag, positionOffset: positionOffset);

  // ignore: experimental_member_use, reason: StreamAudioResponse is the proxy response contract.
  Future<StreamAudioResponse> _request() async {
    // ignore: experimental_member_use, reason: Reuse the lock-cache proxy's per-request cancellation owner.
    unawaited(StreamAudioSource.requestCancellation?.then((_) => cancel()));
    final response = await _ready.future;
    if (_cancelled) throw StateError('Seek preview cancelled');
    if (_output != null) throw StateError('Seek preview already consumed');
    late final StreamController<List<int>> output;
    output = StreamController<List<int>>(
      onListen: () {
        _buffer.forEach(output.add);
        _buffer.clear();
        _bufferedBytes = 0;
        if (_error case final error?) output.addError(error, _stack);
        if (_done) {
          unawaited(output.close());
        } else {
          _subscription?.resume();
        }
      },
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: cancel,
    );
    _output = output;
    // ignore: experimental_member_use, reason: Return the existing proxy response contract.
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: null,
      contentLength: response.contentLength < 0 ? null : response.contentLength,
      offset: null,
      stream: output.stream,
      contentType:
          response.headers.contentType?.mimeType ?? 'application/octet-stream',
    );
  }
}

// ignore: experimental_member_use, reason: The existing proxy owns stream consumption after adoption.
class _SeekPreviewAudioSource extends StreamAudioSource {
  new(this.owner, {super.tag, super.positionOffset});
  final SeekPreviewRequest owner;
  final _retries = <SeekPreviewRequest>{};
  bool _requested = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    owner.cancel();
    for (final retry in _retries) {
      retry.cancel();
    }
    _retries.clear();
  }

  @override
  // ignore: experimental_member_use, reason: Implement the existing proxy response contract.
  Future<StreamAudioResponse> request([int? start, int? end]) {
    if (_disposed) {
      return Future.error(StateError('Seek preview source disposed'));
    }
    if (!_requested) {
      _requested = true;
      return owner._request();
    }
    // Native probes and reconnects reopen the same linear offset stream.
    final retry = SeekPreviewRequest(owner._uri, userAgent: owner._userAgent);
    _retries.add(retry);
    unawaited(retry._finished.future.then((_) => _retries.remove(retry)));
    return retry._request();
  }
}
