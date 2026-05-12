import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:uuid/uuid.dart';

final groupListeningAvailabilityProvider = Provider<GroupListeningAvailability>(
  (ref) {
    final settings = ref.watch(groupListeningSettingsProvider);
    final resolvedVoyageServerUrl = ref.watch(
      groupListeningResolvedVoyageServerUrlProvider,
    );
    final activeServer = ref.watch(serverConfigStateProvider).asData?.value;
    return resolveGroupListeningAvailability(
      enabled: settings.enabled,
      voyageServerUrl: resolvedVoyageServerUrl,
      activeServer: activeServer,
    );
  },
);

final groupListeningClientConfigurationProvider =
    Provider<GroupListeningClientConfiguration?>((ref) {
      final settings = ref.watch(groupListeningSettingsProvider);
      final resolvedVoyageServerUrl = ref.watch(
        groupListeningResolvedVoyageServerUrlProvider,
      );
      final activeServer = ref.watch(serverConfigStateProvider).asData?.value;
      return buildGroupListeningClientConfiguration(
        enabled: settings.enabled,
        voyageServerUrl: resolvedVoyageServerUrl,
        activeServer: activeServer,
        autoFollowHost: settings.autoFollowHost,
      );
    });

final groupListeningSessionCredentialStoreProvider =
    Provider<GroupListeningSessionCredentialStore>((_) {
      return const FlutterSecureGroupListeningSessionCredentialStore();
    });

final groupListeningHttpClientProvider = Provider<GroupListeningHttpClient>((
  _,
) {
  return VoyageGroupListeningHttpClient();
});

final groupListeningRealtimeTransportProvider =
    Provider<GroupListeningRealtimeTransportClient>((_) {
      return const IOWebSocketGroupListeningRealtimeTransportClient();
    });

final groupListeningRepositoryProvider = Provider<GroupListeningRepository>((
  ref,
) {
  return DefaultGroupListeningRepository(
    httpClient: ref.watch(groupListeningHttpClientProvider),
    realtimeTransport: ref.watch(groupListeningRealtimeTransportProvider),
  );
});

final groupListeningCapabilityDiscoveryProvider =
    FutureProvider.autoDispose<GroupListeningCapabilityDiscovery?>((ref) async {
      final availability = ref.watch(groupListeningAvailabilityProvider);
      if (availability != GroupListeningAvailability.ready) {
        return null;
      }
      final configuration = ref.watch(
        groupListeningClientConfigurationProvider,
      );
      if (configuration == null) {
        return null;
      }
      final resolved = await _resolveBestBundledVoyageServer(
        ref,
        configuration,
      );
      return resolved?.discovery ??
          ref.read(groupListeningRepositoryProvider).discover(configuration);
    });

final groupListeningAvailableRoomsProvider =
    FutureProvider.autoDispose<List<GroupListeningAvailableRoomSummary>>((
      ref,
    ) async {
      final availability = ref.watch(groupListeningAvailabilityProvider);
      if (availability != GroupListeningAvailability.ready) {
        return const <GroupListeningAvailableRoomSummary>[];
      }
      final configuration = ref.watch(
        groupListeningClientConfigurationProvider,
      );
      if (configuration == null) {
        return const <GroupListeningAvailableRoomSummary>[];
      }
      final resolved = await _resolveBestBundledVoyageServer(
        ref,
        configuration,
      );
      final effectiveConfiguration = resolved == null
          ? configuration
          : _configurationWithVoyageBaseUrl(
              configuration,
              Uri.parse(resolved.option.url),
            );
      return ref
          .read(groupListeningRepositoryProvider)
          .listAvailableRooms(effectiveConfiguration);
    });

Future<GroupListeningResolvedVoyageServer?> _resolveBestBundledVoyageServer(
  Ref ref,
  GroupListeningClientConfiguration configuration, {
  String? preferredUrl,
}) async {
  final bundledServers = ref.read(groupListeningBundledVoyageServersProvider);
  if (bundledServers.isEmpty) {
    return null;
  }
  final settings = ref.read(groupListeningSettingsProvider);
  if (!settings.enabled) {
    return null;
  }
  final selectedUrl = normalizeVoyageBaseUri(
    preferredUrl ?? settings.voyageServerUrl,
  )?.toString();
  final repository = ref.read(groupListeningRepositoryProvider);
  final probes = await Future.wait(
    bundledServers.map((server) async {
      final uri = normalizeVoyageBaseUri(server.url);
      if (uri == null || !isVoyageTransportAllowed(uri)) {
        return null;
      }
      try {
        final discovery = await repository.discover(
          _configurationWithVoyageBaseUrl(configuration, uri),
        );
        if (!discovery.supportsCurrentProtocol) {
          return null;
        }
        return GroupListeningResolvedVoyageServer(
          option: server,
          discovery: discovery,
        );
      } on Object {
        return null;
      }
    }),
  );
  final candidates = probes.nonNulls.toList(growable: false);
  if (candidates.isEmpty) {
    return null;
  }
  candidates.sort((a, b) {
    final versionCompare = _compareSemanticVersions(
      b.discovery.serverVersion,
      a.discovery.serverVersion,
    );
    if (versionCompare != 0) {
      return versionCompare;
    }
    final aSelected = selectedUrl != null && a.option.url == selectedUrl;
    final bSelected = selectedUrl != null && b.option.url == selectedUrl;
    if (aSelected != bSelected) {
      return aSelected ? -1 : 1;
    }
    return bundledServers
        .indexOf(a.option)
        .compareTo(
          bundledServers.indexOf(b.option),
        );
  });
  return candidates.first;
}

GroupListeningClientConfiguration _configurationWithVoyageBaseUrl(
  GroupListeningClientConfiguration configuration,
  Uri voyageBaseUrl,
) {
  return GroupListeningClientConfiguration(
    voyageBaseUrl: voyageBaseUrl,
    sourceServerOrigin: configuration.sourceServerOrigin,
    sourceServerFingerprint: configuration.sourceServerFingerprint,
    displayName: configuration.displayName,
    deviceLabel: configuration.deviceLabel,
    autoFollowHost: configuration.autoFollowHost,
    allowInsecureTransport: voyageBaseUrl.scheme == 'http',
  );
}

enum GroupListeningVoyageConnectionState {
  disabled,
  unconfigured,
  checking,
  connected,
  failed,
}

@immutable
class GroupListeningVoyageConnectionStatus {
  const GroupListeningVoyageConnectionStatus({
    required this.state,
    required this.message,
    this.userActionMessage,
  });

  final GroupListeningVoyageConnectionState state;
  final String message;
  final String? userActionMessage;

  bool get isHealthy => state == GroupListeningVoyageConnectionState.connected;
}

final groupListeningVoyageConnectionStatusProvider =
    Provider<GroupListeningVoyageConnectionStatus>((ref) {
      final settings = ref.watch(groupListeningSettingsProvider);
      final availability = ref.watch(groupListeningAvailabilityProvider);
      final discoveryAsync = ref.watch(
        groupListeningCapabilityDiscoveryProvider,
      );

      if (!settings.enabled) {
        return GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.disabled,
          message: 'Listen Together is off.',
        );
      }
      if (availability != GroupListeningAvailability.ready) {
        final resolvedVoyageServerUrl = ref.watch(
          groupListeningResolvedVoyageServerUrlProvider,
        );
        return GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.unconfigured,
          message: 'Not connected to Voyage.',
          userActionMessage: _voyageUserActionMessage(
            voyageServerUrl: resolvedVoyageServerUrl,
            availability: availability,
          ),
        );
      }

      return discoveryAsync.when(
        data: (_) => GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.connected,
          message: 'Successfully connected to Voyage.',
        ),
        loading: () => GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.checking,
          message: 'Checking Voyage connection...',
        ),
        error: (error, _) => GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.failed,
          message: 'Not connected to Voyage.',
          userActionMessage: _voyageDiscoveryUserActionMessage(error),
        ),
      );
    });

String? _voyageUserActionMessage({
  required String? voyageServerUrl,
  required GroupListeningAvailability availability,
}) {
  if (availability != GroupListeningAvailability.unconfigured) {
    return null;
  }
  final uri = normalizeVoyageBaseUri(voyageServerUrl);
  if (uri == null) {
    return 'Enter a valid Voyage server URL.';
  }
  if (!isVoyageTransportAllowed(uri)) {
    return 'Use HTTPS for Voyage, or a local HTTP server in debug builds.';
  }
  return 'Sign in to your Subsonic server before using Listen Together.';
}

String? _voyageDiscoveryUserActionMessage(Object error) {
  final failure = error is GroupListeningRepositoryException
      ? error.failure
      : null;
  if (failure == null) {
    return null;
  }
  return switch (failure.code) {
    GroupListeningErrorCode.unsupportedProtocolVersion =>
      'Update Navis or choose a Voyage server with a compatible protocol.',
    GroupListeningErrorCode.validationFailed =>
      'Check the Voyage server configuration and try again.',
    GroupListeningErrorCode.insecureTransport =>
      'Use HTTPS for Voyage, or a local HTTP server in debug builds.',
    GroupListeningErrorCode.transportUnavailable
        when failure.message.isNotEmpty =>
      failure.message,
    _ => null,
  };
}

@immutable
class GroupListeningResolvedVoyageServer {
  const GroupListeningResolvedVoyageServer({
    required this.option,
    required this.discovery,
  });

  final GroupListeningVoyageServerOption option;
  final GroupListeningCapabilityDiscovery discovery;
}

final groupListeningClientDescriptorProvider =
    Provider<GroupListeningClientDescriptor>((ref) {
      final configuration = ref.watch(
        groupListeningClientConfigurationProvider,
      );
      final packageInfo = ref.watch(packageInfoProvider).asData?.value;
      final fingerprint = configuration?.sourceServerFingerprint ?? 'local';
      final fingerprintPrefix = fingerprint.length <= 12
          ? fingerprint
          : fingerprint.substring(0, 12);
      final rawDeviceId = <String>[
        packageInfo?.packageName ?? 'navis',
        defaultTargetPlatform.name,
        configuration?.deviceLabel ??
            configuration?.displayName ??
            defaultGroupListeningDeviceLabel(),
        fingerprintPrefix,
      ].join('-');
      return GroupListeningClientDescriptor(
        appVersion: packageInfo?.version ?? 'dev',
        platform: defaultTargetPlatform.name,
        deviceId: _normalizeGroupListeningDeviceId(rawDeviceId),
        deviceLabel:
            configuration?.deviceLabel ?? defaultGroupListeningDeviceLabel(),
        capabilities: const <String>{
          'playback_anchor',
          'queue_add',
          'queue_remove',
          'queue_replace',
        },
      );
    });

final groupListeningSessionControllerProvider =
    NotifierProvider<
      GroupListeningSessionController,
      GroupListeningSessionState
    >(GroupListeningSessionController.new);

String _normalizeGroupListeningDeviceId(String rawValue) {
  var normalized = rawValue
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-');
  normalized = normalized.replaceFirst(RegExp(r'^-+'), '');
  normalized = normalized.replaceFirst(RegExp(r'-+$'), '');
  if (normalized.isEmpty) {
    return 'navis-${defaultTargetPlatform.name}';
  }
  return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
}

int _compareSemanticVersions(String left, String right) {
  final leftParts = _semanticVersionParts(left);
  final rightParts = _semanticVersionParts(right);
  for (var index = 0; index < leftParts.length; index++) {
    final compare = leftParts[index].compareTo(rightParts[index]);
    if (compare != 0) {
      return compare;
    }
  }
  return left.compareTo(right);
}

List<int> _semanticVersionParts(String version) {
  final match = RegExp(r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(
    version.trim(),
  );
  if (match == null) {
    return const <int>[0, 0, 0];
  }
  return <int>[
    int.tryParse(match.group(1) ?? '') ?? 0,
    int.tryParse(match.group(2) ?? '') ?? 0,
    int.tryParse(match.group(3) ?? '') ?? 0,
  ];
}

class GroupListeningSessionController
    extends Notifier<GroupListeningSessionState> {
  static const Uuid _uuid = Uuid();
  static const Duration _tokenRefreshWindow = Duration(minutes: 1);
  static const Duration _serverUpgradeCheckInterval = Duration(minutes: 5);
  static const Duration _serverMigrationTimeout = Duration(seconds: 15);

  static const Duration _snapshotRetryDelay = Duration(seconds: 5);
  static const Duration _ackLagGrace = Duration(seconds: 2);
  static const Duration _reconnectInitialDelay = Duration(seconds: 2);
  static const Duration _reconnectMaxDelay = Duration(seconds: 60);
  static const int _reconnectMaxAttempts = 8;

  GroupListeningClientConfiguration? _configuration;
  GroupListeningSessionRuntimeContext? _runtimeSession;
  GroupListeningRealtimeConnection? _connection;
  StreamSubscription<GroupListeningTransportMessage>? _transportSubscription;
  Timer? _heartbeatTimer;
  Timer? _serverUpgradeTimer;
  Timer? _snapshotRetryTimer;
  Timer? _reconnectTimer;
  Timer? _ackLagTimer;
  Future<GroupListeningSessionState>? _snapshotRefreshOperation;
  bool _snapshotRefreshInFlight = false;
  bool _queuedSnapshotRefresh = false;
  String? _queuedSnapshotRefreshReason;
  int _reconnectAttempts = 0;
  int? _ackLagRoomVersion;
  GroupListeningCapabilityDiscovery? _connectingDiscovery;
  bool _serverUpgradeInProgress = false;
  bool _transportTeardownInProgress = false;
  bool _transportTeardownFailureObserved = false;
  int _clientSequence = 0;

  @override
  GroupListeningSessionState build() {
    _configuration = ref.read(groupListeningClientConfigurationProvider);
    final availability = ref.read(groupListeningAvailabilityProvider);

    ref.listen<GroupListeningAvailability>(
      groupListeningAvailabilityProvider,
      (_, next) => _handleAvailabilityChanged(next),
    );
    ref.listen<GroupListeningClientConfiguration?>(
      groupListeningClientConfigurationProvider,
      (_, next) => _handleConfigurationChanged(next),
    );
    ref.onDispose(() {
      unawaited(_disposeTransport());
      _serverUpgradeTimer?.cancel();
    });

    return GroupListeningSessionState(
      availability: availability,
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      configuration: _configuration,
    );
  }

  Future<GroupListeningCapabilityDiscovery> discoverCapabilities() async {
    try {
      final resolved = await _resolveBestBundledServer();
      if (resolved != null) {
        return resolved.discovery;
      }
      return ref
          .read(groupListeningRepositoryProvider)
          .discover(
            _requireConfiguration(),
          );
    } on Object catch (error, stackTrace) {
      _setFailure(
        _asFailure(
          error,
          fallbackMessage: 'Unable to discover Voyage capabilities.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        ),
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<GroupListeningSessionState> createRoom({
    required GroupListeningClientDescriptor client,
    GroupListeningRoomOptions roomOptions = const GroupListeningRoomOptions(),
    GroupListeningRoomSeed? roomSeed,
    bool connectAfterCreate = true,
  }) async {
    try {
      final configuration = await _configurationForRoomOperation();
      state = state.copyWith(
        status: GroupListeningSessionStatus.joining,
        clearFailure: true,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .createRoom(
            GroupListeningCreateRoomRequest(
              configuration: configuration,
              client: client,
              roomOptions: roomOptions,
              roomSeed: roomSeed,
            ),
          );
      await _bindJoinedSession(
        result: result,
        client: client,
        connectAfterJoin: connectAfterCreate,
      );
      return state;
    } on Object catch (error, stackTrace) {
      return _setFailure(
        _asFailure(
          error,
          fallbackMessage: 'Unable to create Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        ),
        stackTrace: stackTrace,
      );
    }
  }

  Future<GroupListeningSessionState> joinRoom({
    required String inviteCode,
    required GroupListeningClientDescriptor client,
    String? pinCode,
    bool connectAfterJoin = true,
  }) async {
    try {
      final configuration = await _configurationForRoomOperation();
      state = state.copyWith(
        status: GroupListeningSessionStatus.joining,
        clearFailure: true,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .joinRoom(
            GroupListeningJoinRoomRequest(
              configuration: configuration,
              client: client,
              inviteCode: inviteCode,
              pinCode: pinCode,
            ),
          );
      await _bindJoinedSession(
        result: result,
        client: client,
        connectAfterJoin: connectAfterJoin,
      );
      return state;
    } on Object catch (error, stackTrace) {
      return _setFailure(
        _asFailure(
          error,
          fallbackMessage: 'Unable to join Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        ),
        stackTrace: stackTrace,
      );
    }
  }

  Future<GroupListeningSessionState> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientDescriptor client,
    String? pinCode,
    bool connectAfterJoin = true,
  }) async {
    try {
      final configuration = await _configurationForRoomOperation();
      state = state.copyWith(
        status: GroupListeningSessionStatus.joining,
        clearFailure: true,
        clearActiveInviteCode: true,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .joinAvailableRoom(
            roomId: roomId,
            configuration: configuration,
            client: client,
            pinCode: pinCode,
          );
      await _bindJoinedSession(
        result: result,
        client: client,
        connectAfterJoin: connectAfterJoin,
      );
      return state;
    } on Object catch (error, stackTrace) {
      return _setFailure(
        _asFailure(
          error,
          fallbackMessage: 'Unable to join available Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        ),
        stackTrace: stackTrace,
      );
    }
  }

  Future<GroupListeningSessionState> connect() async {
    final session = _runtimeSession;
    if (session == null) {
      return _setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No active Voyage session is available to connect.',
        ),
      );
    }

    state = state.copyWith(
      status:
          state.connection.status == GroupListeningConnectionStatus.connected
          ? GroupListeningSessionStatus.connected
          : GroupListeningSessionStatus.connecting,
      connection: state.connection.copyWith(
        status:
            state.connection.status == GroupListeningConnectionStatus.connected
            ? GroupListeningConnectionStatus.connected
            : GroupListeningConnectionStatus.connecting,
        clearDisconnectReason: true,
      ),
      clearFailure: true,
    );

    try {
      await _disposeTransport();
      _clientSequence = 0;
      final freshSession = await _ensureFreshSession();
      _connectingDiscovery = await _discoverSessionServer(freshSession);
      final connection = await ref
          .read(groupListeningRepositoryProvider)
          .connect(
            GroupListeningTransportConnectRequest(
              session: freshSession,
              lastAppliedRoomVersion: state.lastAppliedRoomVersion,
            ),
          );
      _connection = connection;
      _transportSubscription = connection.messages.listen(
        _handleTransportMessage,
        onError: (Object error, StackTrace stackTrace) {
          _handleTransportFailure(
            _asFailure(
              error,
              fallbackMessage: 'Voyage transport stream failed.',
              fallbackCode: GroupListeningErrorCode.transportDisconnected,
            ),
            stackTrace: stackTrace,
          );
        },
      );
      return state;
    } on Object catch (error, stackTrace) {
      final failure = _asFailure(
        error,
        fallbackMessage: 'Unable to connect to Voyage room realtime transport.',
        fallbackCode: GroupListeningErrorCode.transportUnavailable,
      );
      if (_shouldCollapseToLocalCleanup(failure.code)) {
        return _finishInvalidatedSessionCleanup(failure);
      }
      if (_shouldAutoReconnectAfterFailure(failure)) {
        _scheduleAutoReconnect();
      }
      return _setFailure(
        failure,
        connectionStatus: GroupListeningConnectionStatus.disconnected,
        stackTrace: stackTrace,
      );
    }
  }

  Future<String?> sendMutation({
    required GroupListeningMutationType type,
    GroupListeningPlaybackAnchor? playbackAnchor,
    GroupListeningQueueState? queue,
    String? targetQueueEntryId,
    String? targetMemberId,
  }) async {
    final connection = _connection;
    final clientConnectionId = state.connection.clientConnectionId;
    if (!_canSendMutationType(type) ||
        connection == null ||
        clientConnectionId == null) {
      return null;
    }

    final mutationId = _uuid.v4();
    final clientSequence = ++_clientSequence;
    try {
      await connection.send(
        GroupListeningMutationMessage(
          type: type,
          expectedRoomVersion: state.lastAppliedRoomVersion,
          clientMutationId: mutationId,
          clientConnectionId: clientConnectionId,
          clientSequence: clientSequence,
          playbackAnchor: playbackAnchor,
          queue: queue,
          targetQueueEntryId: targetQueueEntryId,
          targetMemberId: targetMemberId,
        ),
      );
      return mutationId;
    } on Object catch (error, stackTrace) {
      _handleTransportFailure(
        _asFailure(
          error,
          fallbackMessage: 'Unable to send Voyage room mutation.',
          fallbackCode: GroupListeningErrorCode.transportDisconnected,
        ),
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<GroupListeningSessionState> disconnect({
    bool preserveSession = true,
  }) async {
    state = state.copyWith(
      status: GroupListeningSessionStatus.disconnecting,
      connection: state.connection.copyWith(
        status: GroupListeningConnectionStatus.disconnected,
      ),
      clearFailure: true,
    );
    await _disposeTransport();
    if (!preserveSession) {
      _runtimeSession = null;
      await ref.read(groupListeningSessionCredentialStoreProvider).clear();
    }
    state = state.copyWith(
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      clearRoom: !preserveSession,
      lastAppliedRoomVersion: preserveSession
          ? state.lastAppliedRoomVersion
          : 0,
      snapshotRequired: preserveSession ? state.snapshotRequired : false,
    );
    return state;
  }

  Future<GroupListeningSessionState> leaveRoom({
    String source = 'unknown',
  }) async {
    final session = _runtimeSession;
    if (session == null) {
      return disconnect(preserveSession: false);
    }
    _logRoomAction('leave room', source: source);

    state = state.copyWith(
      status: GroupListeningSessionStatus.leaving,
      clearFailure: true,
    );
    _beginTransportTeardown();
    try {
      try {
        await _runAuthenticatedWithRejoinRetry(
          (freshSession) => ref
              .read(groupListeningRepositoryProvider)
              .leaveRoom(
                freshSession,
                lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              ),
          fallbackMessage: 'Unable to leave Voyage room cleanly.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
      } on Object catch (error, stackTrace) {
        final failure = _asFailure(
          error,
          fallbackMessage: 'Unable to leave Voyage room cleanly.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        final gracefulTransportTeardown =
            failure.code == GroupListeningErrorCode.transportUnavailable &&
            _transportTeardownFailureObserved;
        // Fatal codes mean the server already considers us gone (room closed,
        // token revoked, unauthorised). A transport failure that arrives while
        // teardown is already in progress is also treated as a graceful leave.
        if (!_canLeaveLocallyAfterFailure(failure) &&
            !gracefulTransportTeardown) {
          return _setFailure(failure, stackTrace: stackTrace);
        }
        AppLogger.warning(
          'Leave request rejected (${failure.code}), leaving locally.',
        );
      }

      return _finishLocalLeave();
    } finally {
      _endTransportTeardown();
    }
  }

  Future<GroupListeningSessionState> closeRoom({
    String source = 'unknown',
  }) async {
    final session = _runtimeSession;
    final room = state.room;
    if (session == null || room == null) {
      return _setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No active Voyage room is available to close.',
        ),
      );
    }
    if (!room.self.canManageRoom) {
      return _setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.forbidden,
          message: 'Only the host can close this room.',
        ),
      );
    }
    _logRoomAction('close room', source: source);

    state = state.copyWith(
      status: GroupListeningSessionStatus.disconnecting,
      clearFailure: true,
    );
    _beginTransportTeardown();
    try {
      try {
        final result = await _runAuthenticatedWithRejoinRetry(
          (freshSession) => ref
              .read(groupListeningRepositoryProvider)
              .closeRoom(
                freshSession,
                expectedRoomVersion: state.lastAppliedRoomVersion,
              ),
          fallbackMessage: 'Unable to close Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        await _disposeTransport();
        _runtimeSession = null;
        await ref.read(groupListeningSessionCredentialStoreProvider).clear();
        final latestRoom = state.room ?? room;
        state = state.copyWith(
          status: GroupListeningSessionStatus.idle,
          connection: const GroupListeningConnectionState.disconnected(),
          room: latestRoom.copyWith(
            roomStatus: result.roomStatus,
            roomVersion: result.roomVersion,
            serverTime: result.closedAt,
          ),
          lastAppliedRoomVersion: result.roomVersion,
          snapshotRequired: false,
          clearActiveInviteCode: true,
          clearFailure: true,
        );
        return state;
      } on Object catch (error, stackTrace) {
        final failure = _asFailure(
          error,
          fallbackMessage: 'Unable to close Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        final roomAlreadyClosed =
            state.room?.roomStatus == GroupListeningRoomStatus.closed ||
            failure.code == GroupListeningErrorCode.roomClosed;
        final gracefulTransportTeardown =
            failure.code == GroupListeningErrorCode.transportUnavailable &&
            _transportTeardownFailureObserved;
        if (!roomAlreadyClosed && !gracefulTransportTeardown) {
          if (_shouldCollapseToLocalCleanup(failure.code)) {
            return _finishInvalidatedSessionCleanup(failure);
          }
          return _setFailure(failure, stackTrace: stackTrace);
        }

        AppLogger.warning(
          'Close request rejected (${failure.code}), cleaning up locally.',
        );
        await _disposeTransport();
        _runtimeSession = null;
        await ref.read(groupListeningSessionCredentialStoreProvider).clear();
        final latestRoom = switch (state.room) {
          final current?
              when failure.code == GroupListeningErrorCode.roomClosed ||
                  gracefulTransportTeardown =>
            current.copyWith(
              roomStatus: GroupListeningRoomStatus.closed,
              serverTime: DateTime.now(),
            ),
          final current? => current,
          null => null,
        };
        state = state.copyWith(
          status: GroupListeningSessionStatus.idle,
          connection: const GroupListeningConnectionState.disconnected(),
          room: latestRoom,
          clearRoom: latestRoom == null,
          lastAppliedRoomVersion: latestRoom?.roomVersion ?? 0,
          snapshotRequired: false,
          clearActiveInviteCode: true,
          clearFailure: true,
        );
        return state;
      }
    } finally {
      _endTransportTeardown();
    }
  }

  Future<GroupListeningSessionState> rotateInvite({
    String source = 'unknown',
  }) async {
    final room = state.room;
    if (_runtimeSession == null || room == null) {
      return _setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No active Voyage room is available.',
        ),
      );
    }
    if (!room.self.canManageRoom) {
      return _setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.forbidden,
          message: 'Only the host can rotate the invite.',
        ),
      );
    }
    _logRoomAction('rotate invite', source: source);

    try {
      final result = await _runAuthenticatedWithRejoinRetry(
        (freshSession) => ref
            .read(groupListeningRepositoryProvider)
            .rotateInvite(
              freshSession,
              expectedRoomVersion: state.lastAppliedRoomVersion,
            ),
        fallbackMessage: 'Unable to rotate Voyage invite.',
        fallbackCode: GroupListeningErrorCode.transportUnavailable,
      );
      state = state.copyWith(
        room: state.room?.copyWith(roomVersion: result.roomVersion),
        lastAppliedRoomVersion: result.roomVersion,
        activeInviteCode: result.inviteCode,
        clearFailure: true,
      );
      return state;
    } on Object catch (error, stackTrace) {
      final failure = _asFailure(
        error,
        fallbackMessage: 'Unable to rotate Voyage invite.',
        fallbackCode: GroupListeningErrorCode.transportUnavailable,
      );
      if (_shouldCollapseToLocalCleanup(failure.code)) {
        return _finishInvalidatedSessionCleanup(failure);
      }
      return _setFailure(
        failure,
        stackTrace: stackTrace,
      );
    }
  }

  Future<GroupListeningSessionState> reconnect() async {
    try {
      final configuration = await _configurationForRoomOperation(
        preferStoredServer: true,
      );
      final storedSession = await ref
          .read(groupListeningSessionCredentialStoreProvider)
          .read();
      if (storedSession == null) {
        return _setFailure(
          const GroupListeningErrorState(
            code: GroupListeningErrorCode.sessionUnavailable,
            message: 'No stored Voyage rejoin session is available.',
          ),
        );
      }
      if (storedSession.sourceServerFingerprint !=
          configuration.sourceServerFingerprint) {
        await ref.read(groupListeningSessionCredentialStoreProvider).clear();
        _runtimeSession = null;
        return _setFailure(
          const GroupListeningErrorState(
            code: GroupListeningErrorCode.fingerprintMismatch,
            message: 'Stored Voyage session does not match the active server.',
          ),
        );
      }

      state = state.copyWith(
        status: GroupListeningSessionStatus.reconnecting,
        connection: state.connection.copyWith(
          status: GroupListeningConnectionStatus.reconnecting,
          reconnectAttempt: state.connection.reconnectAttempt + 1,
          clearDisconnectReason: true,
        ),
        clearFailure: true,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .rejoinRoom(
            GroupListeningRejoinRoomRequest(
              configuration: configuration,
              session: storedSession.copyWith(
                lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              ),
            ),
          );
      await _bindJoinedSession(
        result: result,
        client: storedSession.client,
        connectAfterJoin: true,
      );
      return state;
    } on Object catch (error, stackTrace) {
      final failure = _asFailure(
        error,
        fallbackMessage: 'Unable to rejoin Voyage room.',
        fallbackCode: GroupListeningErrorCode.transportUnavailable,
      );
      if (_shouldCollapseToLocalCleanup(failure.code)) {
        return _finishInvalidatedSessionCleanup(failure);
      }
      if (_shouldAutoReconnectAfterFailure(failure)) {
        _scheduleAutoReconnect();
      }
      if (_isFatalSessionFailure(failure.code)) {
        await ref.read(groupListeningSessionCredentialStoreProvider).clear();
        _runtimeSession = null;
      }
      return _setFailure(failure, stackTrace: stackTrace);
    }
  }

  Future<GroupListeningSessionState> refreshSnapshot({
    String reason = 'manual',
  }) async {
    final session = _runtimeSession;
    if (session == null) {
      return _setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message:
              'No active Voyage session is available for snapshot refresh.',
        ),
      );
    }
    if (_snapshotRefreshInFlight) {
      _queuedSnapshotRefresh = true;
      _queuedSnapshotRefreshReason = reason;
      AppLogger.info(
        'Group listening: coalescing snapshot refresh '
        '(reason=$reason, last_applied=${state.lastAppliedRoomVersion})',
      );
      return _snapshotRefreshOperation ??
          Future<GroupListeningSessionState>.value(state);
    }
    _snapshotRefreshInFlight = true;
    AppLogger.info(
      'Group listening: refreshing snapshot '
      '(reason=$reason, last_applied=${state.lastAppliedRoomVersion})',
    );
    final operation = () async {
      try {
        final snapshot = await _runAuthenticatedWithRejoinRetry(
          (freshSession) => ref
              .read(groupListeningRepositoryProvider)
              .fetchSnapshot(
                freshSession,
                lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              ),
          fallbackMessage: 'Unable to refresh Voyage room snapshot.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        return applySnapshot(snapshot);
      } on Object catch (error, stackTrace) {
        final failure = _asFailure(
          error,
          fallbackMessage: 'Unable to refresh Voyage room snapshot.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        if (_shouldCollapseToLocalCleanup(failure.code)) {
          return _finishInvalidatedSessionCleanup(failure);
        }
        // If the WS connection is still alive, don't tear down the session just
        // because the HTTP snapshot fetch failed. Leave snapshotRequired=true so
        // the retry timer or the bridge will attempt again.
        if (state.connection.isConnected) {
          AppLogger.warning(
            'Group listening: snapshot fetch failed (reason=$reason, '
            'non-fatal, WS alive): ${failure.code.name} — ${failure.message}',
          );
          _scheduleSnapshotRetry();
          return state;
        }
        return _setFailure(failure, stackTrace: stackTrace);
      }
    }();
    _snapshotRefreshOperation = operation;
    try {
      return await operation;
    } finally {
      _snapshotRefreshOperation = null;
      _snapshotRefreshInFlight = false;
      final queuedRefresh = _queuedSnapshotRefresh;
      final queuedReason = _queuedSnapshotRefreshReason;
      _queuedSnapshotRefresh = false;
      _queuedSnapshotRefreshReason = null;
      if (queuedRefresh && state.snapshotRequired) {
        unawaited(
          refreshSnapshot(
            reason: queuedReason == null
                ? 'coalesced-retry'
                : 'coalesced-retry:$queuedReason',
          ),
        );
      }
    }
  }

  GroupListeningSessionState applySnapshot(GroupListeningRoomState snapshot) {
    final configuration = _configuration;
    if (configuration == null) {
      return _setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.configurationMissing,
          message: 'Voyage configuration is not ready.',
        ),
      );
    }
    if (snapshot.sourceServerFingerprint !=
        configuration.sourceServerFingerprint) {
      unawaited(ref.read(groupListeningSessionCredentialStoreProvider).clear());
      _runtimeSession = null;
      return _setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.fingerprintMismatch,
          message:
              'Voyage snapshot fingerprint does not match the active server.',
        ),
        clearRoom: true,
      );
    }
    if (state.room != null && snapshot.roomId != state.room!.roomId) {
      return state;
    }
    // Allow re-applying a snapshot at the current version so that a
    // snapshotRequired flag set by a stale_version rejection (which arrived
    // after the corresponding room event already advanced lastApplied) can be
    // cleared.  Using strict-less-than here means an equal-version snapshot
    // still goes through applySnapshot and clears snapshotRequired at line
    // below, rather than silently returning with the flag still set.
    if (snapshot.roomVersion < state.lastAppliedRoomVersion) {
      return state;
    }

    state = state.copyWith(
      status: snapshot.roomStatus == GroupListeningRoomStatus.closed
          ? GroupListeningSessionStatus.idle
          : state.connection.isConnected
          ? GroupListeningSessionStatus.connected
          : GroupListeningSessionStatus.idle,
      connection: snapshot.roomStatus == GroupListeningRoomStatus.closed
          ? const GroupListeningConnectionState.disconnected()
          : state.connection,
      room: snapshot,
      lastAppliedRoomVersion: snapshot.roomVersion,
      snapshotRequired: false,
      lastSnapshotAt: DateTime.now(),
      clearActiveInviteCode:
          snapshot.roomStatus == GroupListeningRoomStatus.closed,
      clearFailure: true,
    );
    _snapshotRetryTimer?.cancel();
    _snapshotRetryTimer = null;
    _clearAckLagRecovery(upToRoomVersion: snapshot.roomVersion);
    if (snapshot.roomStatus == GroupListeningRoomStatus.closed) {
      _runtimeSession = null;
      unawaited(ref.read(groupListeningSessionCredentialStoreProvider).clear());
    }
    unawaited(
      _persistLastAppliedVersion(
        snapshot.roomVersion,
        expectedSession: _runtimeSession,
      ),
    );
    return state;
  }

  GroupListeningSessionState applyRealtimeEvent(GroupListeningRoomEvent event) {
    final room = state.room;
    if (room == null || room.roomId != event.roomId) {
      return _requestSnapshotRecovery(
        'room-event-before-snapshot',
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.snapshotRequired,
          message: 'Voyage room event arrived before a room snapshot.',
        ),
      );
    }
    if (event.roomVersion <= state.lastAppliedRoomVersion) {
      return state;
    }
    if (event.previousRoomVersion != state.lastAppliedRoomVersion ||
        event.roomVersion != state.lastAppliedRoomVersion + 1) {
      return _requestSnapshotRecovery(
        'room-event-gap',
        GroupListeningErrorState(
          code: GroupListeningErrorCode.snapshotRequired,
          message: 'Voyage room version gap detected.',
          retryable: true,
          roomVersion: event.roomVersion,
          details: <String, Object?>{
            'last_applied_room_version': state.lastAppliedRoomVersion,
            'incoming_room_version': event.roomVersion,
          },
        ),
      );
    }

    state = state.copyWith(
      room: room.applyEvent(event),
      lastAppliedRoomVersion: event.roomVersion,
      snapshotRequired: false,
      clearFailure: true,
    );
    _clearAckLagRecovery(upToRoomVersion: event.roomVersion);
    unawaited(
      _persistLastAppliedVersion(
        event.roomVersion,
        expectedSession: _runtimeSession,
      ),
    );

    if (event.roomStatus == GroupListeningRoomStatus.closed ||
        event.eventType == GroupListeningRoomEventType.roomClosed) {
      state = state.copyWith(
        status: GroupListeningSessionStatus.idle,
        connection: const GroupListeningConnectionState.disconnected(),
      );
    }
    return state;
  }

  GroupListeningSessionState markSnapshotRequired([
    GroupListeningErrorState? failure,
  ]) {
    _clearAckLagRecovery();
    state = state.copyWith(
      snapshotRequired: true,
      failure:
          failure ??
          const GroupListeningErrorState(
            code: GroupListeningErrorCode.snapshotRequired,
            message: 'Voyage state is stale and requires a fresh snapshot.',
            retryable: true,
          ),
      status: state.connection.isConnected
          ? GroupListeningSessionStatus.connected
          : state.status,
    );
    _scheduleSnapshotRetry();
    return state;
  }

  /// Schedules a one-shot timer to call [refreshSnapshot] if [snapshotRequired]
  /// is still true after [_snapshotRetryDelay]. This acts as a safety net when
  /// the bridge misses the false→true transition (e.g. concurrent in-flight
  /// refresh) or when the initial HTTP call failed non-fatally.
  void _scheduleSnapshotRetry() {
    _snapshotRetryTimer?.cancel();
    if (!state.connection.isConnected) {
      return;
    }
    _snapshotRetryTimer = Timer(_snapshotRetryDelay, () {
      if (state.snapshotRequired && state.connection.isConnected) {
        AppLogger.info('Group listening: retrying snapshot refresh via timer');
        unawaited(refreshSnapshot(reason: 'snapshot-retry-timer'));
      }
    });
  }

  GroupListeningSessionState _requestSnapshotRecovery(
    String reason, [
    GroupListeningErrorState? failure,
  ]) {
    final effectiveFailure =
        failure ??
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.snapshotRequired,
          message: 'Voyage state is stale and requires a fresh snapshot.',
          retryable: true,
        );
    AppLogger.info(
      'Group listening: snapshot required '
      '(reason=$reason, code=${effectiveFailure.code.name}, '
      'last_applied=${state.lastAppliedRoomVersion}, '
      'room_version=${effectiveFailure.roomVersion ?? state.room?.roomVersion ?? 0})',
    );
    return markSnapshotRequired(effectiveFailure);
  }

  void _logRoomAction(String action, {required String source}) {
    AppLogger.info(
      'Group listening: $action requested '
      '(source=$source, room_id=${state.room?.roomId ?? _runtimeSession?.roomId ?? 'n/a'}, '
      'room_version=${state.lastAppliedRoomVersion})',
    );
  }

  void clearFailure() {
    state = state.copyWith(clearFailure: true);
  }

  Future<T> _runAuthenticatedWithRejoinRetry<T>(
    Future<T> Function(GroupListeningSessionRuntimeContext session) operation, {
    required String fallbackMessage,
    required GroupListeningErrorCode fallbackCode,
  }) async {
    var session = await _ensureFreshSession();
    try {
      return await operation(session);
    } on Object catch (error) {
      final failure = _asFailure(
        error,
        fallbackMessage: fallbackMessage,
        fallbackCode: fallbackCode,
      );
      if (failure.code != GroupListeningErrorCode.unauthorized) {
        rethrow;
      }
      session = await _ensureFreshSession(force: true);
      return operation(session);
    }
  }

  Future<GroupListeningSessionRuntimeContext> _ensureFreshSession({
    bool force = false,
  }) async {
    final session = _runtimeSession;
    if (session == null) {
      throw const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No active Voyage session is available.',
        ),
      );
    }
    if (!force &&
        session.accessTokenExpiresAt
                .difference(DateTime.now().toUtc())
                .compareTo(_tokenRefreshWindow) >
            0) {
      return session;
    }
    return _rejoinCurrentSession(session);
  }

  Future<GroupListeningSessionRuntimeContext> _rejoinCurrentSession(
    GroupListeningSessionRuntimeContext expectedSession,
  ) async {
    final configuration = _configurationWithVoyageBaseUrl(
      _requireConfiguration(),
      expectedSession.voyageBaseUrl,
    );
    final store = ref.read(groupListeningSessionCredentialStoreProvider);
    final storedSession = await store.read();
    if (storedSession == null ||
        !_matchesStoredSession(storedSession, expectedSession)) {
      throw const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No stored Voyage rejoin session is available.',
        ),
      );
    }
    final result = await ref
        .read(groupListeningRepositoryProvider)
        .rejoinRoom(
          GroupListeningRejoinRoomRequest(
            configuration: configuration,
            session: storedSession.copyWith(
              lastAppliedRoomVersion: state.lastAppliedRoomVersion,
            ),
          ),
        );
    _runtimeSession = result.runtimeContext;
    applySnapshot(result.roomSnapshot);
    state = state.copyWith(
      activeInviteCode: result.inviteCode,
      clearActiveInviteCode: result.inviteCode == null,
    );
    await store.save(
      GroupListeningStoredSession(
        roomId: result.runtimeContext.roomId,
        memberId: result.runtimeContext.memberId,
        role: result.runtimeContext.role,
        authVersion: result.runtimeContext.authVersion,
        voyageBaseUrl: result.runtimeContext.voyageBaseUrl,
        sourceServerFingerprint: result.runtimeContext.sourceServerFingerprint,
        rejoinToken: result.runtimeContext.rejoinToken,
        client: storedSession.client,
        lastAppliedRoomVersion: result.roomSnapshot.roomVersion,
      ),
    );
    return result.runtimeContext;
  }

  Future<void> _bindJoinedSession({
    required GroupListeningJoinResponse result,
    required GroupListeningClientDescriptor client,
    required bool connectAfterJoin,
  }) async {
    _runtimeSession = result.runtimeContext;
    final storedSession = GroupListeningStoredSession(
      roomId: result.runtimeContext.roomId,
      memberId: result.runtimeContext.memberId,
      role: result.runtimeContext.role,
      authVersion: result.runtimeContext.authVersion,
      voyageBaseUrl: result.runtimeContext.voyageBaseUrl,
      sourceServerFingerprint: result.runtimeContext.sourceServerFingerprint,
      rejoinToken: result.runtimeContext.rejoinToken,
      client: client,
      lastAppliedRoomVersion: result.roomSnapshot.roomVersion,
    );
    applySnapshot(result.roomSnapshot);
    state = state.copyWith(
      activeInviteCode: result.inviteCode,
      clearActiveInviteCode: result.inviteCode == null,
    );
    await ref
        .read(groupListeningSessionCredentialStoreProvider)
        .save(storedSession);
    if (connectAfterJoin) {
      await connect();
    } else {
      state = state.copyWith(
        status: GroupListeningSessionStatus.idle,
        connection: const GroupListeningConnectionState.disconnected(),
      );
    }
  }

  void _handleTransportMessage(GroupListeningTransportMessage message) {
    if (message is GroupListeningConnectionWelcomeMessage) {
      _scheduleHeartbeat(after: message.heartbeatInterval);
      // Successful connection — cancel any pending auto-reconnect and reset
      // the attempt counter so the next drop starts fresh.
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempts = 0;
      _clearAckLagRecovery();
      final connectedDiscovery = _connectingDiscovery;
      _connectingDiscovery = null;
      final connectedSession = _runtimeSession;
      state = state.copyWith(
        status: GroupListeningSessionStatus.connected,
        connection: state.connection.copyWith(
          status: GroupListeningConnectionStatus.connected,
          clientConnectionId: message.clientConnectionId,
          heartbeatInterval: message.heartbeatInterval,
          memberStaleTimeout: message.memberStaleTimeout,
          connectedAt: DateTime.now(),
          lastServerTime: message.serverTime,
          connectedServerUrl: connectedSession?.voyageBaseUrl,
          connectedServerVersion: connectedDiscovery?.serverVersion,
          clearDisconnectReason: true,
        ),
        clearFailure: true,
      );
      _scheduleServerUpgradeCheck();
      return;
    }
    if (message is GroupListeningRoomSnapshotMessage) {
      applySnapshot(message.snapshot);
      return;
    }
    if (message is GroupListeningRoomEventMessage) {
      applyRealtimeEvent(message.event);
      return;
    }
    if (message is GroupListeningPresenceUpdatedMessage) {
      final room = state.room;
      if (room == null || room.roomId != message.roomId) {
        return;
      }
      if (message.roomVersion < state.lastAppliedRoomVersion) {
        return;
      }
      if (message.roomVersion > state.lastAppliedRoomVersion + 1) {
        // Genuine gap: multiple room events are missing. Fetch a fresh snapshot.
        _requestSnapshotRecovery(
          'presence-gap',
          GroupListeningErrorState(
            code: GroupListeningErrorCode.snapshotRequired,
            message: 'Voyage presence update arrived ahead of room state.',
            retryable: true,
            roomVersion: message.roomVersion,
          ),
        );
        return;
      }
      if (message.roomVersion > state.lastAppliedRoomVersion) {
        // Presence arrived exactly 1 version ahead of lastApplied: the
        // corresponding room.event is still in transit on the WS stream.
        // Skip this presence frame; the event will arrive momentarily and
        // advance lastAppliedRoomVersion, at which point the next presence
        // notification (at the new version) will apply normally.
        return;
      }
      state = state.copyWith(
        room: room.copyWith(
          presenceVersion: message.presenceVersion,
          members: _mergeMembers(
            existing: room.members,
            updates: message.members,
            removedMemberIds: const <String>[],
          ),
        ),
      );
      return;
    }
    if (message is GroupListeningHeartbeatAckMessage) {
      final receivedAt = DateTime.now();
      state = state.copyWith(
        connection: state.connection.copyWith(
          lastHeartbeatAckAt: receivedAt,
          lastServerTime: message.serverTime,
        ),
      );
      if (!state.snapshotRequired &&
          message.roomVersion > state.lastAppliedRoomVersion) {
        _scheduleAckLagRecovery(message.roomVersion);
      } else {
        _clearAckLagRecovery(upToRoomVersion: state.lastAppliedRoomVersion);
      }
      return;
    }
    if (message is GroupListeningRoomClosedMessage) {
      _runtimeSession = null;
      unawaited(ref.read(groupListeningSessionCredentialStoreProvider).clear());
      state = state.copyWith(
        status: GroupListeningSessionStatus.idle,
        connection: const GroupListeningConnectionState.disconnected(),
        clearActiveInviteCode: true,
        room: state.room?.copyWith(
          roomStatus: GroupListeningRoomStatus.closed,
          roomVersion: message.roomVersion,
          serverTime: message.closedAt,
        ),
      );
      return;
    }
    if (message is GroupListeningTransportDisconnectedMessage) {
      _handleTransportFailure(
        message.error ??
            const GroupListeningErrorState(
              code: GroupListeningErrorCode.transportDisconnected,
              message: 'Voyage realtime transport disconnected.',
              retryable: true,
            ),
      );
      return;
    }
    if (message is GroupListeningMutationRejectedMessage) {
      // Non-fatal mutation rejection (forbidden / sequence_rejected /
      // duplicate_mutation).  Log it but do NOT tear down the session.
      AppLogger.info(
        'Group listening mutation rejected: '
        '${message.error.code.name} — ${message.error.message}',
      );
      return;
    }
    if (message is GroupListeningTransportErrorMessage) {
      _handleTransportFailure(message.error);
    }
  }

  void _handleTransportFailure(
    GroupListeningErrorState failure, {
    StackTrace? stackTrace,
  }) {
    // Only cancel the heartbeat for non-recoverable failures that actually
    // tear down the transport.  Recoverable errors (stale_version,
    // snapshotRequired) keep the WS connection alive — stopping the heartbeat
    // here causes the server to mark this client as stale after
    // memberStaleTimeout, which is the root cause of the "sync disconnects
    // within seconds" symptom.
    final isRecoverable =
        failure.code == GroupListeningErrorCode.snapshotRequired ||
        failure.code == GroupListeningErrorCode.staleVersion;
    if (!isRecoverable) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
    }
    if (_transportTeardownInProgress) {
      _transportTeardownFailureObserved = true;
      return;
    }
    if (stackTrace != null) {
      AppLogger.warning(
        'Group listening transport failure: ${failure.code.name}',
      );
    }
    if (failure.code == GroupListeningErrorCode.snapshotRequired ||
        failure.code == GroupListeningErrorCode.staleVersion) {
      _requestSnapshotRecovery('transport-${failure.code.name}', failure);
      return;
    }
    if (_shouldCollapseToLocalCleanup(failure.code)) {
      unawaited(_finishInvalidatedSessionCleanup(failure));
      return;
    }
    if (failure.code == GroupListeningErrorCode.unsupportedProtocolVersion ||
        failure.code == GroupListeningErrorCode.transportUnavailable ||
        failure.code == GroupListeningErrorCode.transportDisconnected) {
      unawaited(_checkForBundledServerUpgrade(triggeredByFailure: true));
    }
    if (_isFatalSessionFailure(failure.code)) {
      _snapshotRetryTimer?.cancel();
      _snapshotRetryTimer = null;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempts = 0;
      _runtimeSession = null;
      unawaited(ref.read(groupListeningSessionCredentialStoreProvider).clear());
    }
    state = state.copyWith(
      status: GroupListeningSessionStatus.error,
      connection: state.connection.copyWith(
        status: GroupListeningConnectionStatus.disconnected,
        lastDisconnectReason: failure,
      ),
      clearActiveInviteCode: _isFatalSessionFailure(failure.code),
      failure: failure,
    );
    // Auto-reconnect on retryable transport disconnects (e.g. network blip,
    // server restart).  We use exponential backoff and cap attempts so the
    // user is shown an error if the server is truly unreachable.
    if (_shouldAutoReconnectAfterFailure(failure)) {
      _scheduleAutoReconnect();
    }
  }

  void _scheduleAutoReconnect() {
    _reconnectTimer?.cancel();
    if (_reconnectAttempts >= _reconnectMaxAttempts) {
      AppLogger.warning(
        'Group listening: auto-reconnect exhausted after '
        '$_reconnectAttempts attempts',
      );
      return;
    }
    final attempt = _reconnectAttempts + 1;
    final backoff = Duration(
      milliseconds:
          (_reconnectInitialDelay.inMilliseconds *
                  (1 << (_reconnectAttempts).clamp(0, 5)))
              .clamp(
                _reconnectInitialDelay.inMilliseconds,
                _reconnectMaxDelay.inMilliseconds,
              ),
    );
    AppLogger.info(
      'Group listening: scheduling auto-reconnect attempt $attempt in '
      '${backoff.inSeconds}s',
    );
    _reconnectTimer = Timer(backoff, () {
      if (_runtimeSession == null || state.connection.isConnected) {
        return;
      }
      _reconnectAttempts = attempt;
      AppLogger.info(
        'Group listening: auto-reconnect attempt $_reconnectAttempts',
      );
      unawaited(reconnect());
    });
  }

  bool _shouldAutoReconnectAfterFailure(GroupListeningErrorState failure) {
    return failure.retryable == true &&
        _runtimeSession != null &&
        !_isFatalSessionFailure(failure.code) &&
        (failure.code == GroupListeningErrorCode.transportDisconnected ||
            failure.code == GroupListeningErrorCode.transportUnavailable);
  }

  bool _shouldCollapseToLocalCleanup(GroupListeningErrorCode code) {
    return code == GroupListeningErrorCode.unauthorized ||
        code == GroupListeningErrorCode.removed ||
        code == GroupListeningErrorCode.revoked;
  }

  bool _canLeaveLocallyAfterFailure(GroupListeningErrorState failure) {
    return _isFatalSessionFailure(failure.code) ||
        failure.code == GroupListeningErrorCode.transportDisconnected ||
        failure.code == GroupListeningErrorCode.transportUnavailable;
  }

  void _handleAvailabilityChanged(GroupListeningAvailability availability) {
    state = state.copyWith(availability: availability);
    if (availability != GroupListeningAvailability.ready &&
        (state.connection.status !=
                GroupListeningConnectionStatus.disconnected ||
            _runtimeSession != null ||
            state.room != null)) {
      unawaited(_resetForConfigurationLoss());
    }
  }

  void _handleConfigurationChanged(GroupListeningClientConfiguration? next) {
    final previous = _configuration;
    _configuration = next;
    state = state.copyWith(configuration: next);

    if (previous != null &&
        next != null &&
        !previous.isTransportCompatibleWith(next) &&
        !_runtimeSessionMatchesConfiguration(next) &&
        (state.room != null || _runtimeSession != null)) {
      unawaited(_resetForConfigurationLoss());
    }
  }

  Future<void> _resetForConfigurationLoss() async {
    await _disposeTransport();
    _runtimeSession = null;
    await ref.read(groupListeningSessionCredentialStoreProvider).clear();
    state = state.copyWith(
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      clearRoom: true,
      clearFailure: true,
      lastAppliedRoomVersion: 0,
      snapshotRequired: false,
    );
  }

  Future<void> _persistLastAppliedVersion(
    int roomVersion, {
    required GroupListeningSessionRuntimeContext? expectedSession,
  }) async {
    if (expectedSession == null || !_matchesRuntimeSession(expectedSession)) {
      return;
    }
    final store = ref.read(groupListeningSessionCredentialStoreProvider);
    final current = await store.read();
    if (current == null ||
        !_matchesStoredSession(current, expectedSession) ||
        !_matchesRuntimeSession(expectedSession)) {
      return;
    }
    await store.save(current.copyWith(lastAppliedRoomVersion: roomVersion));
  }

  bool _matchesRuntimeSession(GroupListeningSessionRuntimeContext expected) {
    final current = _runtimeSession;
    if (current == null) {
      return false;
    }
    return current.roomId == expected.roomId &&
        current.memberId == expected.memberId &&
        current.sourceServerFingerprint == expected.sourceServerFingerprint;
  }

  bool _matchesStoredSession(
    GroupListeningStoredSession stored,
    GroupListeningSessionRuntimeContext expected,
  ) {
    return stored.roomId == expected.roomId &&
        stored.memberId == expected.memberId &&
        stored.sourceServerFingerprint == expected.sourceServerFingerprint;
  }

  bool _runtimeSessionMatchesConfiguration(
    GroupListeningClientConfiguration configuration,
  ) {
    final session = _runtimeSession;
    return session != null &&
        session.voyageBaseUrl == configuration.voyageBaseUrl &&
        session.sourceServerFingerprint ==
            configuration.sourceServerFingerprint;
  }

  bool _canSendMutationType(GroupListeningMutationType type) {
    final room = state.room;
    final configuration = state.configuration;
    if (room == null ||
        configuration == null ||
        state.availability != GroupListeningAvailability.ready ||
        !state.connection.isConnected ||
        state.snapshotRequired ||
        room.roomStatus != GroupListeningRoomStatus.active ||
        room.sourceServerFingerprint != configuration.sourceServerFingerprint) {
      return false;
    }

    switch (type) {
      case GroupListeningMutationType.queueAdd:
      case GroupListeningMutationType.queueRemove:
        return room.self.canControl;
      case GroupListeningMutationType.queueReplace:
        return room.self.canControl;
      case GroupListeningMutationType.playbackAnchor:
      case GroupListeningMutationType.transferHost:
      case GroupListeningMutationType.removeMember:
        return room.self.canControl;
    }
  }

  Future<GroupListeningClientConfiguration> _configurationForRoomOperation({
    bool preferStoredServer = false,
  }) async {
    final configuration = _requireConfiguration();
    final resolved = await _resolveBestBundledServer(
      preferredUrl: preferStoredServer
          ? (await ref
                    .read(groupListeningSessionCredentialStoreProvider)
                    .read())
                ?.voyageBaseUrl
                .toString()
          : null,
    );
    if (resolved == null) {
      return configuration;
    }
    return _configurationWithVoyageBaseUrl(
      configuration,
      Uri.parse(resolved.option.url),
    );
  }

  Future<GroupListeningResolvedVoyageServer?> _resolveBestBundledServer({
    String? preferredUrl,
  }) async {
    final configuration = _configuration;
    if (configuration == null ||
        state.availability != GroupListeningAvailability.ready) {
      return null;
    }
    return _resolveBestBundledVoyageServer(
      ref,
      configuration,
      preferredUrl: preferredUrl,
    );
  }

  Future<GroupListeningCapabilityDiscovery> _discoverSessionServer(
    GroupListeningSessionRuntimeContext session,
  ) {
    final configuration = _requireConfiguration();
    return ref
        .read(groupListeningRepositoryProvider)
        .discover(
          _configurationWithVoyageBaseUrl(configuration, session.voyageBaseUrl),
        );
  }

  GroupListeningClientConfiguration _requireConfiguration() {
    final configuration = _configuration;
    if (configuration == null ||
        state.availability != GroupListeningAvailability.ready) {
      throw const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.configurationMissing,
          message: 'Voyage settings are incomplete or disabled.',
        ),
      );
    }
    return configuration;
  }

  Future<void> _disposeTransport() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _serverUpgradeTimer?.cancel();
    _serverUpgradeTimer = null;
    _snapshotRetryTimer?.cancel();
    _snapshotRetryTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _clearAckLagRecovery();
    _reconnectAttempts = 0;
    _connectingDiscovery = null;
    await _transportSubscription?.cancel();
    _transportSubscription = null;
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      await connection.disconnect();
    }
  }

  Future<GroupListeningSessionState> _finishLocalLeave() async {
    await _disposeTransport();
    _runtimeSession = null;
    await ref.read(groupListeningSessionCredentialStoreProvider).clear();
    state = state.copyWith(
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      clearRoom: true,
      clearFailure: true,
      lastAppliedRoomVersion: 0,
      snapshotRequired: false,
    );
    return state;
  }

  Future<GroupListeningSessionState> _finishInvalidatedSessionCleanup(
    GroupListeningErrorState failure,
  ) async {
    AppLogger.warning(
      'Group listening: session invalidated by ${failure.code.name}; '
      'cleaning up locally.',
    );
    await _disposeTransport();
    _runtimeSession = null;
    await ref.read(groupListeningSessionCredentialStoreProvider).clear();
    state = state.copyWith(
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      clearRoom: true,
      lastAppliedRoomVersion: 0,
      snapshotRequired: false,
      clearActiveInviteCode: true,
      failure: failure,
    );
    return state;
  }

  void _scheduleHeartbeat({Duration? after}) {
    _heartbeatTimer?.cancel();
    final delay = after ?? state.connection.heartbeatInterval;
    if (delay == null || delay <= Duration.zero) {
      return;
    }
    _heartbeatTimer = Timer(delay, () {
      unawaited(_sendHeartbeat());
    });
  }

  void _scheduleAckLagRecovery(int roomVersion) {
    if (roomVersion <= state.lastAppliedRoomVersion) {
      _clearAckLagRecovery();
      return;
    }
    if (_ackLagRoomVersion == roomVersion &&
        (_ackLagTimer?.isActive ?? false)) {
      return;
    }
    _ackLagTimer?.cancel();
    _ackLagRoomVersion = roomVersion;
    _ackLagTimer = Timer(_ackLagGrace, () {
      final stillLagging =
          state.connection.isConnected &&
          !state.snapshotRequired &&
          state.lastAppliedRoomVersion < roomVersion;
      if (!stillLagging) {
        _clearAckLagRecovery(upToRoomVersion: state.lastAppliedRoomVersion);
        return;
      }
      AppLogger.info(
        'Group listening: heartbeat ack stayed ahead of room state; '
        'requesting snapshot recovery',
      );
      _requestSnapshotRecovery(
        'heartbeat-ack-lag',
        GroupListeningErrorState(
          code: GroupListeningErrorCode.snapshotRequired,
          message: 'Heartbeat ack indicates the room state is lagging behind.',
          retryable: true,
          roomVersion: roomVersion,
          details: <String, Object?>{
            'last_applied_room_version': state.lastAppliedRoomVersion,
            'ack_room_version': roomVersion,
          },
        ),
      );
      _clearAckLagRecovery();
    });
  }

  void _clearAckLagRecovery({int? upToRoomVersion}) {
    final trackedRoomVersion = _ackLagRoomVersion;
    if (upToRoomVersion != null &&
        trackedRoomVersion != null &&
        trackedRoomVersion > upToRoomVersion) {
      return;
    }
    _ackLagTimer?.cancel();
    _ackLagTimer = null;
    _ackLagRoomVersion = null;
  }

  Future<void> _sendHeartbeat() async {
    final connection = _connection;
    final clientConnectionId = state.connection.clientConnectionId;
    if (connection == null ||
        clientConnectionId == null ||
        !state.connection.isConnected) {
      return;
    }

    final interval = state.connection.heartbeatInterval;
    if (interval == null || interval <= Duration.zero) {
      return;
    }

    final observedPosition = ref.read(playerStateProvider).position;
    try {
      await connection.send(
        GroupListeningHeartbeatMessage(
          clientConnectionId: clientConnectionId,
          clientTime: DateTime.now().toUtc(),
          lastAppliedRoomVersion: state.lastAppliedRoomVersion,
          observedPosition: observedPosition,
        ),
      );
      _scheduleHeartbeat(after: interval);
    } on Object catch (error, stackTrace) {
      _handleTransportFailure(
        _asFailure(
          error,
          fallbackMessage: 'Unable to send Voyage heartbeat.',
          fallbackCode: GroupListeningErrorCode.transportDisconnected,
        ),
        stackTrace: stackTrace,
      );
    }
  }

  void _scheduleServerUpgradeCheck() {
    _serverUpgradeTimer?.cancel();
    if (!state.connection.isConnected) {
      return;
    }
    _serverUpgradeTimer = Timer(_serverUpgradeCheckInterval, () {
      unawaited(_checkForBundledServerUpgrade());
    });
  }

  Future<void> _checkForBundledServerUpgrade({
    bool triggeredByFailure = false,
  }) async {
    if (_serverUpgradeInProgress ||
        _runtimeSession == null ||
        !state.connection.isConnected) {
      return;
    }
    final currentVersion = state.connection.connectedServerVersion;
    final currentUrl = _runtimeSession?.voyageBaseUrl.toString();
    if (currentVersion == null || currentUrl == null) {
      _scheduleServerUpgradeCheck();
      return;
    }

    final candidate = await _resolveBestBundledServer(preferredUrl: currentUrl);
    if (candidate == null ||
        candidate.option.url == currentUrl ||
        _compareSemanticVersions(
              candidate.discovery.serverVersion,
              currentVersion,
            ) <=
            0) {
      if (!triggeredByFailure) {
        _scheduleServerUpgradeCheck();
      }
      return;
    }
    await _migrateToBundledServer(candidate);
    if (!triggeredByFailure) {
      _scheduleServerUpgradeCheck();
    }
  }

  Future<void> _migrateToBundledServer(
    GroupListeningResolvedVoyageServer candidate,
  ) async {
    _serverUpgradeInProgress = true;
    GroupListeningRealtimeConnection? candidateConnection;
    StreamSubscription<GroupListeningTransportMessage>? candidateSubscription;
    try {
      final currentSession = _runtimeSession;
      final baseConfiguration = _requireConfiguration();
      if (currentSession == null) {
        return;
      }
      final store = ref.read(groupListeningSessionCredentialStoreProvider);
      final storedSession = await store.read();
      if (storedSession == null ||
          !_matchesStoredSession(storedSession, currentSession)) {
        return;
      }
      final nextUri = Uri.parse(candidate.option.url);
      final nextConfiguration = _configurationWithVoyageBaseUrl(
        baseConfiguration,
        nextUri,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .rejoinRoom(
            GroupListeningRejoinRoomRequest(
              configuration: nextConfiguration,
              session: storedSession.copyWith(
                voyageBaseUrl: nextUri,
                lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              ),
            ),
          );
      candidateConnection = await ref
          .read(groupListeningRepositoryProvider)
          .connect(
            GroupListeningTransportConnectRequest(
              session: result.runtimeContext,
              lastAppliedRoomVersion: state.lastAppliedRoomVersion,
            ),
          );

      final messages = <GroupListeningTransportMessage>[];
      final ready = Completer<void>();
      GroupListeningConnectionWelcomeMessage? welcome;
      GroupListeningRoomSnapshotMessage? snapshot;
      candidateSubscription = candidateConnection.messages.listen(
        (message) {
          messages.add(message);
          if (message is GroupListeningConnectionWelcomeMessage) {
            welcome = message;
          }
          if (message is GroupListeningRoomSnapshotMessage) {
            snapshot = message;
          }
          if (welcome != null && snapshot != null && !ready.isCompleted) {
            ready.complete();
          }
          if (message is GroupListeningTransportErrorMessage &&
              !ready.isCompleted) {
            ready.completeError(
              GroupListeningRepositoryException(message.error),
            );
          }
          if (message is GroupListeningTransportDisconnectedMessage &&
              !ready.isCompleted) {
            ready.completeError(
              GroupListeningRepositoryException(
                message.error ??
                    const GroupListeningErrorState(
                      code: GroupListeningErrorCode.transportDisconnected,
                      message: 'Voyage realtime transport disconnected.',
                      retryable: true,
                    ),
              ),
            );
          }
        },
        onError: ready.completeError,
      );
      await ready.future.timeout(_serverMigrationTimeout);

      final oldConnection = _connection;
      final oldSubscription = _transportSubscription;
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      await oldSubscription?.cancel();
      _connection = candidateConnection;
      _transportSubscription = candidateConnection.messages.listen(
        _handleTransportMessage,
        onError: (Object error, StackTrace stackTrace) {
          _handleTransportFailure(
            _asFailure(
              error,
              fallbackMessage: 'Voyage transport stream failed.',
              fallbackCode: GroupListeningErrorCode.transportDisconnected,
            ),
            stackTrace: stackTrace,
          );
        },
      );
      await candidateSubscription.cancel();
      candidateSubscription = null;
      candidateConnection = null;
      await oldConnection?.disconnect();

      _runtimeSession = result.runtimeContext;
      _connectingDiscovery = candidate.discovery;
      for (final message in messages) {
        if (message is GroupListeningConnectionWelcomeMessage ||
            message is GroupListeningRoomSnapshotMessage) {
          _handleTransportMessage(message);
        }
      }
      state = state.copyWith(
        activeInviteCode: result.inviteCode,
        clearActiveInviteCode: result.inviteCode == null,
      );
      await store.save(
        GroupListeningStoredSession(
          roomId: result.runtimeContext.roomId,
          memberId: result.runtimeContext.memberId,
          role: result.runtimeContext.role,
          authVersion: result.runtimeContext.authVersion,
          voyageBaseUrl: result.runtimeContext.voyageBaseUrl,
          sourceServerFingerprint:
              result.runtimeContext.sourceServerFingerprint,
          rejoinToken: result.runtimeContext.rejoinToken,
          client: storedSession.client,
          lastAppliedRoomVersion: state.lastAppliedRoomVersion,
        ),
      );
      await _persistSelectedVoyageServer(result.runtimeContext.voyageBaseUrl);
    } on Object catch (error) {
      AppLogger.warning('Voyage bundled server migration failed: $error');
      await candidateSubscription?.cancel();
      await candidateConnection?.disconnect();
    } finally {
      _serverUpgradeInProgress = false;
    }
  }

  Future<void> _persistSelectedVoyageServer(Uri voyageBaseUrl) async {
    final settings =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    await ref
        .read(settingsRepositoryProvider)
        .saveSettings(
          settings.copyWith(voyageServerUrl: voyageBaseUrl.toString()),
        );
  }

  GroupListeningSessionState _setFailure(
    GroupListeningErrorState failure, {
    GroupListeningConnectionStatus? connectionStatus,
    bool clearRoom = false,
    StackTrace? stackTrace,
  }) {
    if (stackTrace != null) {
      AppLogger.warning('Group listening failure: ${failure.code.name}');
    }
    state = state.copyWith(
      status: GroupListeningSessionStatus.error,
      connection: state.connection.copyWith(
        status: connectionStatus ?? state.connection.status,
        lastDisconnectReason: failure,
      ),
      failure: failure,
      clearRoom: clearRoom,
    );
    return state;
  }

  GroupListeningErrorState _asFailure(
    Object error, {
    required String fallbackMessage,
    required GroupListeningErrorCode fallbackCode,
  }) {
    if (error is GroupListeningRepositoryException) {
      return error.failure;
    }
    return GroupListeningErrorState(
      code: fallbackCode,
      message: fallbackMessage,
    );
  }

  bool _isFatalSessionFailure(GroupListeningErrorCode code) {
    return code == GroupListeningErrorCode.fingerprintMismatch ||
        code == GroupListeningErrorCode.removed ||
        code == GroupListeningErrorCode.revoked ||
        code == GroupListeningErrorCode.roomClosed ||
        code == GroupListeningErrorCode.unauthorized;
  }

  void _beginTransportTeardown() {
    _transportTeardownInProgress = true;
    _transportTeardownFailureObserved = false;
  }

  void _endTransportTeardown() {
    _transportTeardownInProgress = false;
    _transportTeardownFailureObserved = false;
  }

  List<GroupListeningMemberState> _mergeMembers({
    required List<GroupListeningMemberState> existing,
    required List<GroupListeningMemberState> updates,
    required List<String> removedMemberIds,
  }) {
    final byId = <String, GroupListeningMemberState>{
      for (final member in existing) member.memberId: member,
    };
    for (final memberId in removedMemberIds) {
      byId.remove(memberId);
    }
    for (final member in updates) {
      byId[member.memberId] = member;
    }
    final merged = byId.values.toList(growable: false)
      ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    return merged;
  }
}
