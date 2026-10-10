import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';

/// Narrow Flutter contract for Android's WorkManager scheduler.
///
/// Only a hash of the retained profile identity crosses this channel. Passwords,
/// server URLs, usernames, and work payload details stay in Dart storage.
class AndroidBackgroundSyncScheduler {
  new({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel(_channelName),
      _supported = supported ?? isSupported;

  static const String _channelName = 'com.navis.app/background_sync';
  final MethodChannel _channel;
  final bool _supported;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static String profileKeyFor(ServerConfigModel config) {
    final identity = '${_normalizeUrl(config.url)}|${config.username.trim()}';
    return sha256.convert(utf8.encode(identity)).toString().substring(0, 32);
  }

  Future<AndroidBackgroundScheduleObservation> configurePeriodic({
    required String profileKey,
    required int intervalMinutes,
    required bool unmeteredOnly,
  }) async {
    if (!_supported) {
      return const AndroidBackgroundScheduleObservation.unsupported();
    }
    return await _invoke('configurePeriodic', <String, Object>{
      'profileKey': profileKey,
      'intervalMinutes': intervalMinutes,
      'unmeteredOnly': unmeteredOnly,
    });
  }

  Future<AndroidBackgroundScheduleObservation> enqueueCatchup({
    required String profileKey,
    required bool unmeteredOnly,
  }) async {
    if (!_supported) {
      return const AndroidBackgroundScheduleObservation.unsupported();
    }
    return await _invoke('enqueueCatchup', <String, Object>{
      'profileKey': profileKey,
      'unmeteredOnly': unmeteredOnly,
    });
  }

  Future<AndroidBackgroundScheduleObservation> cancel({
    required String profileKey,
  }) async {
    if (!_supported) {
      return const AndroidBackgroundScheduleObservation.unsupported();
    }
    return await _invoke('cancel', <String, Object>{'profileKey': profileKey});
  }

  Future<AndroidBackgroundScheduleObservation> status({
    required String profileKey,
  }) async {
    if (!_supported) {
      return const AndroidBackgroundScheduleObservation.unsupported();
    }
    return await _invoke('status', <String, Object>{'profileKey': profileKey});
  }

  Future<AndroidBackgroundScheduleObservation> _invoke(
    String method,
    Map<String, Object> arguments,
  ) async {
    try {
      final result = await _channel.invokeMethod<Object?>(method, arguments);
      return AndroidBackgroundScheduleObservation.fromPlatform(result);
    } on MissingPluginException {
      return const AndroidBackgroundScheduleObservation.unsupported();
    } on PlatformException {
      return const AndroidBackgroundScheduleObservation.platformFailure();
    }
  }

  static String _normalizeUrl(String value) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return value.trim().replaceFirst(RegExp(r'/+$'), '');
    }
    final defaultPort =
        (parsed.scheme.toLowerCase() == 'https' && parsed.port == 443) ||
        (parsed.scheme.toLowerCase() == 'http' && parsed.port == 80);
    return Uri(
      scheme: parsed.scheme.toLowerCase(),
      host: parsed.host.toLowerCase(),
      port: defaultPort ? null : (parsed.hasPort ? parsed.port : null),
      path: parsed.path == '/'
          ? ''
          : parsed.path.replaceFirst(RegExp(r'/+$'), ''),
    ).toString();
  }
}

/// Bounded, redacted observation returned by the native channel.
class AndroidBackgroundScheduleObservation {
  const new({
    required this.available,
    required this.state,
    this.workId,
    this.attemptCount = 0,
    this.workerResult,
    this.workerStopReason,
  });

  factory fromPlatform(Object? value) {
    if (value is! Map) {
      return const AndroidBackgroundScheduleObservation.platformFailure();
    }
    final rawState = value['state']?.toString() ?? 'platformFailure';
    final state = _allowedStates.contains(rawState)
        ? rawState
        : 'platformFailure';
    final rawId = value['workId']?.toString();
    final workId =
        rawId != null && RegExp(r'^[0-9a-fA-F-]{1,64}$').hasMatch(rawId)
        ? rawId
        : null;
    final attemptCount = switch (value['attemptCount']) {
      final int count => count.clamp(0, 100),
      _ => 0,
    };
    final workerResult = _boundedWorkerCategory(value['workerResult']);
    final workerStopReason = _boundedWorkerCategory(value['workerStopReason']);
    return AndroidBackgroundScheduleObservation(
      available: value['available'] == true,
      state: state,
      workId: workId,
      attemptCount: attemptCount,
      workerResult: workerResult,
      workerStopReason: workerStopReason,
    );
  }

  const new unsupported()
    : available = false,
      state = 'unsupported',
      workId = null,
      attemptCount = 0,
      workerResult = null,
      workerStopReason = null;

  const new platformFailure()
    : available = true,
      state = 'platformFailure',
      workId = null,
      attemptCount = 0,
      workerResult = null,
      workerStopReason = null;

  final bool available;
  final String state;
  final String? workId;
  final int attemptCount;
  final String? workerResult;
  final String? workerStopReason;

  static const _allowedStates = <String>{
    'scheduled',
    'running',
    'enqueued',
    'blocked',
    'cancelled',
    'none',
    'unsupported',
    'platformFailure',
    'statusUnavailable',
  };

  static String? _boundedWorkerCategory(Object? value) {
    const allowed = <String>{
      'engineTimeout',
      'stoppedBySystem',
      'transientFailure',
      'bootstrapFailure',
      'bootstrapRetryExhausted',
      'retryCapReached',
      'alreadyDispatching',
      'deferredPlayback',
    };
    final category = value?.toString();
    return allowed.contains(category) ? category : null;
  }
}

/// Reconciles the native schedule with durable app policy. It intentionally
/// owns no sync logic; WorkManager invokes Dart only after this contract has
/// been persisted and constrained natively.
class AndroidBackgroundSyncReconciler {
  new({required this._database, required this._scheduler});

  final NavisDatabase _database;
  final AndroidBackgroundSyncScheduler _scheduler;

  Future<void> reconcile({
    required ServerConfigModel config,
    required int intervalMinutes,
    required bool unmeteredOnly,
    bool enqueueCatchup = false,
  }) async {
    final serverId = config.id;
    if (serverId == null) {
      return;
    }
    final state = await _database.librarySyncDao.getOrCreateState(serverId);
    final key = AndroidBackgroundSyncScheduler.profileKeyFor(config);
    await _importNativeWorkerOutcome(serverId, key);
    if (!state.androidBackgroundSyncEnabled || intervalMinutes <= 0) {
      final observation = await _scheduler.cancel(profileKey: key);
      final failed = observation.state == 'platformFailure';
      await _writeObservation(
        serverId: serverId,
        observation: observation,
        intervalMinutes: null,
        clearRequestedIntervalMinutes: !failed,
        clearWorkId: !failed,
      );
      return;
    }
    final observation = await _scheduler.configurePeriodic(
      profileKey: key,
      intervalMinutes: intervalMinutes,
      unmeteredOnly: unmeteredOnly,
    );
    await _writeObservation(
      serverId: serverId,
      observation: observation,
      intervalMinutes: observation.state == 'platformFailure'
          ? null
          : intervalMinutes,
    );
    if (enqueueCatchup) {
      await this.enqueueCatchup(config: config, unmeteredOnly: unmeteredOnly);
    }
  }

  Future<void> _importNativeWorkerOutcome(
    int serverId,
    String profileKey,
  ) async {
    final observation = await _scheduler.status(profileKey: profileKey);
    if (observation.workerResult == null) return;
    await _database.librarySyncDao.writeAndroidBackgroundStatus(
      serverId: serverId,
      workerResult: observation.workerResult,
      workerStopReason: observation.workerStopReason,
    );
  }

  Future<void> enqueueCatchup({
    required ServerConfigModel config,
    required bool unmeteredOnly,
  }) async {
    final serverId = config.id;
    if (serverId == null) {
      return;
    }
    final state = await _database.librarySyncDao.getOrCreateState(serverId);
    if (!state.androidBackgroundSyncEnabled) {
      return;
    }
    final observation = await _scheduler.enqueueCatchup(
      profileKey: AndroidBackgroundSyncScheduler.profileKeyFor(config),
      unmeteredOnly: unmeteredOnly,
    );
    await _writeObservation(
      serverId: serverId,
      observation: observation,
      intervalMinutes: state.androidRequestedIntervalMinutes,
    );
  }

  Future<void> cancelFor(ServerConfigModel config) async {
    final serverId = config.id;
    if (serverId == null) {
      return;
    }
    final observation = await _scheduler.cancel(
      profileKey: AndroidBackgroundSyncScheduler.profileKeyFor(config),
    );
    final failed = observation.state == 'platformFailure';
    await _writeObservation(
      serverId: serverId,
      observation: observation,
      intervalMinutes: null,
      clearRequestedIntervalMinutes: !failed,
      clearWorkId: !failed,
    );
  }

  Future<void> _writeObservation({
    required int serverId,
    required AndroidBackgroundScheduleObservation observation,
    required int? intervalMinutes,
    bool clearRequestedIntervalMinutes = false,
    bool clearWorkId = false,
  }) {
    return _database.librarySyncDao.writeAndroidBackgroundStatus(
      serverId: serverId,
      scheduleReconciledAt: DateTime.now(),
      requestedIntervalMinutes: intervalMinutes,
      clearRequestedIntervalMinutes: clearRequestedIntervalMinutes,
      workId: observation.workId,
      clearWorkId: clearWorkId,
      workState: observation.state,
      attemptCount: observation.attemptCount,
    );
  }
}
