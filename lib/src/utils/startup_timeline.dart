import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Only bounded, identity-free events may enter the on-device startup history.
enum StartupEvent {
  processStart,
  lifecycle,
  bootstrapStart,
  bootstrapReady,
  bootstrapTimeout,
  bootstrapFailure,
  queueRestoreStart,
  queueRestoreEnd,
  resumeConnectivity,
  resumeReachability,
  resumeDatabase,
  workerEntry,
  workerExit,
  restart,
  mediaServiceRecovery,
  audioFocusRecovery,
  streamRecovery,
  radioRecovery,
  radioRefillRecovery,
  credentialRecovery,
}

enum StartupFailure { timeout, credentials, storage, platform, other }

enum StartupOutcome {
  cold,
  warm,
  resumed,
  inactive,
  paused,
  hidden,
  detached,
  online,
  offline,
  changed,
  unchanged,
  success,
  failure,
  timeout,
  unavailable,
  deferredPlayback,
  noWorkDue,
  deferredPolicy,
  credentialUnavailable,
  deferredSetup,
  deferredUpgrade,
  leaseHeld,
  permanentFailure,
  transientFailure,
  stoppedBySystem,
}

/// Persists a small private ring; the native worker owns a separate file.
///
/// No free-form strings, exceptions, paths or media/account identifiers are
/// accepted. Writes are serialized and copies validate the worker's schema too.
class StartupTimeline {
  new({Future<Directory> Function()? readDirectory, DateTime Function()? now})
    : _readDirectory = readDirectory ?? getApplicationSupportDirectory,
      _now = now ?? DateTime.now;

  static const _workerEvents = {
    StartupEvent.workerEntry,
    StartupEvent.workerExit,
  };
  static const _workerOutcomes = {
    StartupOutcome.success,
    StartupOutcome.failure,
    StartupOutcome.timeout,
    StartupOutcome.deferredPlayback,
    StartupOutcome.deferredPolicy,
    StartupOutcome.noWorkDue,
    StartupOutcome.credentialUnavailable,
    StartupOutcome.deferredSetup,
    StartupOutcome.deferredUpgrade,
    StartupOutcome.leaseHeld,
    StartupOutcome.permanentFailure,
    StartupOutcome.transientFailure,
    StartupOutcome.stoppedBySystem,
  };

  final Future<Directory> Function() _readDirectory;
  final DateTime Function() _now;
  Future<void> _writes = Future<void>.value();
  bool _permissionsSet = false;

  Future<void> record(
    StartupEvent event, {
    int? attempt,
    int? elapsedMs,
    StartupOutcome? outcome,
    StartupFailure? failureType,
  }) {
    final row = <String, Object>{
      'at': _now().toUtc().toIso8601String(),
      'event': event.name,
      if (attempt != null) 'attempt': attempt.clamp(0, 1000000),
      if (elapsedMs != null) 'elapsedMs': elapsedMs.clamp(0, 1000000000),
      if (outcome != null) 'outcome': outcome.name,
      if (failureType != null) 'failureType': failureType.name,
    };
    final task = _writes.then((_) async {
      final root = await _readDirectory();
      await root.create(recursive: true);
      final file = File(p.join(root.path, 'startup-timeline.jsonl'));
      final rows = (await _read(file, 199))..add(row);
      final lines = rows.map(jsonEncode).toList();
      var bytes = lines.fold<int>(
        0,
        (n, line) => n + utf8.encode(line).length + 1,
      );
      while (bytes > 32768 && lines.length > 1) {
        bytes -= utf8.encode(lines.removeAt(0)).length + 1;
      }
      if (!_permissionsSet && (Platform.isLinux || Platform.isMacOS)) {
        await file.create();
        final result = await Process.run('chmod', ['600', file.path]);
        if (result.exitCode != 0) {
          throw const FileSystemException(
            'Private startup storage unavailable',
          );
        }
        _permissionsSet = true;
      }
      await file.writeAsString('${lines.join('\n')}\n', flush: true);
    });
    // A failure must not poison later writes or prevent bootstrap.
    _writes = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<String> copyDetails() async {
    await _writes;
    final root = await _readDirectory();
    final rows = [
      ...await _read(File(p.join(root.path, 'startup-timeline.jsonl')), 200),
      ...await _read(
        File(p.join(root.path, 'startup-worker.jsonl')),
        100,
        worker: true,
      ),
    ]..sort((a, b) => (a['at']! as String).compareTo(b['at']! as String));
    return rows.map(jsonEncode).join('\n');
  }

  Future<List<Map<String, Object>>> _read(
    File file,
    int limit, {
    bool worker = false,
  }) async {
    try {
      // Timeline I/O must stay off the UI thread.
      // ignore: avoid_slow_async_io
      if (!await file.exists() || await file.length() > 32768) return [];
      final rows = <Map<String, Object>>[];
      for (final line in await file.readAsLines()) {
        try {
          final value = jsonDecode(line);
          if (value is! Map<String, dynamic>) continue;
          final at = value['at'];
          final event = value['event'];
          final events = worker
              ? _workerEvents
              : StartupEvent.values.toSet().difference(_workerEvents);
          final outcomes = worker
              ? _workerOutcomes
              : StartupOutcome.values.toSet();
          if (at is! String ||
              at.length > 32 ||
              DateTime.tryParse(at) == null ||
              !events.any((e) => e.name == event)) {
            continue;
          }
          rows.add({
            'at': at,
            'event': event as String,
            if (value['attempt'] case final int n when n >= 0 && n <= 1000000)
              'attempt': n,
            if (value['elapsedMs'] case final int n
                when n >= 0 && n <= 1000000000)
              'elapsedMs': n,
            if (StartupFailure.values.any(
              (e) => e.name == value['failureType'],
            ))
              'failureType': value['failureType'] as String,
            if (outcomes.any((e) => e.name == value['outcome']))
              'outcome': value['outcome'] as String,
          });
        } on FormatException {
          // An interrupted worker append can leave one incomplete line.
        }
      }
      return rows.length <= limit ? rows : rows.sublist(rows.length - limit);
    } on FileSystemException {
      return [];
    }
  }
}
