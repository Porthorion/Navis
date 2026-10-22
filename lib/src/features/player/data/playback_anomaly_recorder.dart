import 'dart:collection';
import 'dart:convert';

import 'package:navis/src/utils/app_logger.dart';

/// Silent recorder for two playback anomalies that no user action explains:
/// a position that moves back more than 2 s on the same queue entry
/// (`backwardJump`), and a song that reached its last 10 s playing again from
/// under 3 s within 10 s (`replayNearEnd`).
///
/// Observe only: it never changes playback. A hit writes one warning, a header
/// line plus one line per transport event of the last 30 s, each prefixed
/// `[PLAYBACK_ANOMALY]`. Rows hold no URLs, song ids, titles or account data.
class PlaybackAnomalyRecorder {
  PlaybackAnomalyRecorder({
    DateTime Function()? now,
    void Function(String)? log,
    Map<String, Object?> Function()? header,
  }) : _now = now ?? DateTime.now,
       _log = log ?? AppLogger.warning,
       _header = header;

  static const _window = Duration(seconds: 30);
  static const _maxRows = 400;
  static const _recentRecords = 5;
  // ponytail: a session cap keeps a broken stream from flooding the log;
  // raise it or persist records if more than 20 per run are ever needed.
  static const _maxRecords = 20;
  static const _jump = Duration(milliseconds: 2000);
  static const _grace = Duration(milliseconds: 1500);
  static const _confirmAfter = Duration(milliseconds: 300);
  static const _confirmWithin = Duration(seconds: 3);
  static const _nearEnd = Duration(seconds: 10);
  static const _replayStart = Duration(seconds: 3);

  final DateTime Function() _now;
  final void Function(String) _log;
  final Map<String, Object?> Function()? _header;

  final _rows = ListQueue<_Row>();
  final _raw = ListQueue<_Row>();
  final _recent = <Map<String, Object?>>[];
  final _recorded = <String, Set<Object>>{};
  var _count = 0;
  _Sample? _prev;
  _Candidate? _candidate;
  _NearEnd? _end;
  DateTime? _expectedAt;
  DateTime? _lastPositionRow;

  /// The last 5 records, newest last: the header fields plus `events`.
  List<Map<String, Object?>> get recent => List.of(_recent);

  /// Adds a transport event to the ring. It explains nothing.
  void event(String kind, [Map<String, Object?> fields = const {}]) {
    final at = _now();
    _rows.add(_Row(at, kind, fields));
    _prune(at);
  }

  /// Adds a transport event that explains a position move (seek, navigation,
  /// loop, stop, deck swap) and forgets the baseline it moves.
  void expect(String kind, [Map<String, Object?> fields = const {}]) {
    event(kind, fields);
    _expectedAt = _now();
    _prev = _candidate = _end = null;
  }

  /// Feeds one position sample, in song time, of the current queue entry
  /// [entryKey] (compared by identity). [seeking] samples are ignored.
  void observePosition({
    required Duration position,
    required Object entryKey,
    required String songId,
    Duration? duration,
    required bool repeatOne,
    required bool playing,
    bool seeking = false,
  }) {
    final at = _now();
    final ms = position.inMilliseconds;
    _raw.add(_Row(at, 'pos', {'ms': ms}));
    while (_raw.length > 3) {
      _raw.removeFirst();
    }
    if (_lastPositionRow == null ||
        at.difference(_lastPositionRow!) >= const Duration(seconds: 1)) {
      _lastPositionRow = at;
      _rows.add(_Row(at, 'pos', {'ms': ms}));
    }
    _prune(at);
    if (seeking || !playing) {
      _candidate = null;
      return;
    }

    final sample = _Sample(position, at, entryKey, songId);
    final previous = _prev;
    final pending = _candidate;
    _prev = sample;
    if (pending != null) {
      final age = at.difference(pending.at);
      if (age < _confirmAfter) return;
      _candidate = null;
      if (age <= _confirmWithin &&
          identical(entryKey, pending.entry) &&
          (pending.kind == 'replayNearEnd'
              ? position < _nearEnd
              : position < pending.from)) {
        _end = null;
        _emit(pending, duration: duration, at: at);
        return;
      }
    }
    final explained =
        _expectedAt != null && at.difference(_expectedAt!) < _grace;
    final end = _end;
    if (duration != null && position >= duration - _nearEnd) {
      _end = _NearEnd(at, entryKey, songId, position);
    }
    if (explained || previous == null) return;

    final sameEntry = identical(entryKey, previous.entry);
    String? kind;
    var from = previous.position;
    if (end != null &&
        !repeatOne &&
        songId == end.songId &&
        position < _replayStart &&
        at.difference(end.at) <= _nearEnd &&
        (!identical(entryKey, end.entry) || end.position - position > _jump)) {
      kind = 'replayNearEnd';
      from = end.position;
    } else if (sameEntry && previous.position - position > _jump) {
      kind = 'backwardJump';
    }
    if (kind != null) {
      _candidate = _Candidate(kind, from, position, at, entryKey, sameEntry);
    }
  }

  void _emit(_Candidate c, {Duration? duration, required DateTime at}) {
    final seen = _recorded.putIfAbsent(c.kind, Set<Object>.identity);
    if (_count >= _maxRecords || !seen.add(c.entry)) return;
    final id = ++_count;
    final header = <String, Object?>{
      'kind': c.kind,
      'fromMs': c.from.inMilliseconds,
      'toMs': c.to.inMilliseconds,
      'durationMs': duration?.inMilliseconds,
      'sameEntry': c.sameEntry,
      ...?_header?.call(),
    };
    // Recent position rows lag by up to a second; the raw samples fill in.
    final rows = <_Row>[
      ..._rows,
      ..._raw.where(
        (r) => _lastPositionRow == null || r.at.isAfter(_lastPositionRow!),
      ),
    ]..sort((a, b) => a.at.compareTo(b.at));
    final events = <Map<String, Object?>>[
      for (final row in rows.skip(
        rows.length > _maxRows ? rows.length - _maxRows : 0,
      ))
        {
          't': row.at.difference(at).inMilliseconds,
          'e': row.kind,
          ...row.fields,
        },
    ];
    // One warning, one short line per row: far below logcat's line limit.
    const tag = '[PLAYBACK_ANOMALY]';
    _log(
      [
        '$tag ${jsonEncode(header)}',
        for (final e in events) '$tag $id ${jsonEncode(e)}',
      ].join('\n'),
    );
    _recent
      ..add({'id': id, ...header, 'events': events})
      ..removeRange(
        0,
        _recent.length > _recentRecords ? _recent.length - _recentRecords : 0,
      );
  }

  void _prune(DateTime at) {
    while (_rows.isNotEmpty &&
        (_rows.length > _maxRows || at.difference(_rows.first.at) > _window)) {
      _rows.removeFirst();
    }
  }
}

class _Row {
  const _Row(this.at, this.kind, this.fields);
  final DateTime at;
  final String kind;
  final Map<String, Object?> fields;
}

class _Sample {
  const _Sample(this.position, this.at, this.entry, this.songId);
  final Duration position;
  final DateTime at;
  final Object entry;
  final String songId;
}

class _NearEnd {
  const _NearEnd(this.at, this.entry, this.songId, this.position);
  final DateTime at;
  final Object entry;
  final String songId;
  final Duration position;
}

class _Candidate {
  const _Candidate(
    this.kind,
    this.from,
    this.to,
    this.at,
    this.entry,
    this.sameEntry,
  );
  final String kind;
  final Duration from;
  final Duration to;
  final DateTime at;
  final Object entry;
  final bool sameEntry;
}
