import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _FakeGroupListeningRepository implements GroupListeningRepository {
  GroupListeningCapabilityDiscovery discovery =
      const GroupListeningCapabilityDiscovery(
        service: 'voyage',
        apiVersion: 'v1',
        supportedProtocolVersions: <String>[voyageProtocolVersion],
        latestProtocolVersion: voyageProtocolVersion,
        websocketPath: '/api/v1/rooms/ws',
        heartbeatInterval: Duration(seconds: 10),
        memberStaleTimeout: Duration(seconds: 45),
      );

  GroupListeningJoinResponse? joinResponse;
  GroupListeningJoinResponse? createResponse;
  GroupListeningJoinResponse? rejoinResponse;
  GroupListeningRoomState? snapshotResponse;
  List<GroupListeningAvailableRoomSummary> availableRooms =
      const <GroupListeningAvailableRoomSummary>[];
  _FakeRealtimeConnection? connection;

  Object? joinError;
  Object? createError;
  Object? rejoinError;
  Object? connectError;
  Object? snapshotError;
  Object? leaveError;

  @override
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  ) async {
    if (connectError != null) {
      throw connectError!;
    }
    return connection!;
  }

  @override
  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  ) async {
    if (createError != null) {
      throw createError!;
    }
    return createResponse!;
  }

  @override
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  ) async {
    return discovery;
  }

  @override
  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  ) async {
    return availableRooms;
  }

  @override
  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
  }) async {
    if (joinError != null) {
      throw joinError!;
    }
    return joinResponse!;
  }

  @override
  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) async {
    if (snapshotError != null) {
      throw snapshotError!;
    }
    return snapshotResponse!;
  }

  @override
  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  ) async {
    if (joinError != null) {
      throw joinError!;
    }
    return joinResponse!;
  }

  @override
  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) async {
    if (leaveError != null) {
      throw leaveError!;
    }
    return GroupListeningLeaveResponse(
      roomId: session.roomId,
      leftMemberId: session.memberId,
      roomStatus: GroupListeningRoomStatus.closed,
      roomVersion: (lastAppliedRoomVersion ?? 0) + 1,
    );
  }

  @override
  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  ) async {
    if (rejoinError != null) {
      throw rejoinError!;
    }
    return rejoinResponse!;
  }
}

class _FakeRealtimeConnection implements GroupListeningRealtimeConnection {
  final _controller =
      StreamController<GroupListeningTransportMessage>.broadcast();
  final sentMessages = <GroupListeningOutboundTransportMessage>[];
  bool disconnected = false;

  @override
  Stream<GroupListeningTransportMessage> get messages => _controller.stream;

  void add(GroupListeningTransportMessage message) {
    _controller.add(message);
  }

  @override
  Future<void> disconnect() async {
    disconnected = true;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  @override
  Future<void> send(GroupListeningOutboundTransportMessage message) async {
    sentMessages.add(message);
  }
}

void main() {
  const activeServer = ServerConfigModel(
    url: 'https://Sub.Example.com/navidrome/',
    username: 'alice',
    password: 'secret',
    apiVersion: '1.16.1',
  );
  const client = GroupListeningClientDescriptor(
    appVersion: '1.0.0',
    platform: 'linux',
    deviceId: 'device-1',
    deviceLabel: 'Desktop',
    capabilities: <String>{'playback_anchor'},
  );

  ProviderContainer createContainer({
    required GroupListeningRepository repository,
    AppSettingsModel? settings,
  }) {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          AsyncData<AppSettingsModel>(
            settings ??
                AppSettingsModel.defaults().copyWith(
                  groupListeningEnabled: true,
                  voyageServerUrl: 'https://voyage.example.com',
                  voyageDeviceLabel: 'Desktop',
                  clearVoyageDisplayName: true,
                ),
          ),
        ),
        serverConfigStateProvider.overrideWithValue(
          const AsyncData(activeServer),
        ),
        groupListeningRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('groupListeningSessionControllerProvider', () {
    test('derives ready availability from active settings and auth state', () {
      final container = createContainer(
        repository: _FakeGroupListeningRepository(),
      );

      final state = container.read(groupListeningSessionControllerProvider);

      expect(state.availability, GroupListeningAvailability.ready);
      expect(state.configuration?.displayName, 'alice');
      expect(
        state.configuration?.sourceServerOrigin,
        'https://sub.example.com/navidrome',
      );
      expect(
        state.configuration?.sourceServerFingerprint,
        computeSourceServerFingerprint(activeServer.url),
      );
    });

    test('transitions from connecting to connected after welcome', () async {
      final repository = _FakeGroupListeningRepository();
      final connection = _FakeRealtimeConnection();
      final fingerprint = computeSourceServerFingerprint(activeServer.url);
      repository.joinResponse = GroupListeningJoinResponse(
        runtimeContext: _runtimeContext(fingerprint: fingerprint),
        roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
      );
      repository.connection = connection;

      final container = createContainer(repository: repository);
      final controller = container.read(
        groupListeningSessionControllerProvider.notifier,
      );

      await controller.joinRoom(
        inviteCode: 'INVITE',
        client: client,
        connectAfterJoin: false,
      );

      final connectFuture = controller.connect();
      var state = container.read(groupListeningSessionControllerProvider);
      expect(state.status, GroupListeningSessionStatus.connecting);
      expect(
        state.connection.status,
        GroupListeningConnectionStatus.connecting,
      );

      await connectFuture;
      connection.add(
        GroupListeningConnectionWelcomeMessage(
          roomId: 'room-1',
          memberId: 'member-1',
          clientConnectionId: 'conn-1',
          roomVersion: 1,
          presenceVersion: 1,
          heartbeatInterval: const Duration(seconds: 10),
          memberStaleTimeout: const Duration(seconds: 45),
          serverTime: DateTime.utc(2026, 4, 21, 12),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(groupListeningSessionControllerProvider);
      expect(state.status, GroupListeningSessionStatus.connected);
      expect(state.connection.status, GroupListeningConnectionStatus.connected);
      expect(state.connection.clientConnectionId, 'conn-1');
    });

    test(
      'connects and marks snapshot required when a room version gap appears',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
        );
        repository.connection = connection;

        final container = createContainer(repository: repository);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        expect(
          container
              .read(groupListeningSessionControllerProvider)
              .room
              ?.roomVersion,
          1,
        );

        await controller.connect();
        connection.add(
          GroupListeningConnectionWelcomeMessage(
            roomId: 'room-1',
            memberId: 'member-1',
            clientConnectionId: 'conn-1',
            roomVersion: 1,
            presenceVersion: 1,
            heartbeatInterval: const Duration(seconds: 10),
            memberStaleTimeout: const Duration(seconds: 45),
            serverTime: DateTime.utc(2026, 4, 21, 12),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          container
              .read(groupListeningSessionControllerProvider)
              .connection
              .status,
          GroupListeningConnectionStatus.connected,
        );

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(roomVersion: 2, previousRoomVersion: 1),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          container
              .read(groupListeningSessionControllerProvider)
              .lastAppliedRoomVersion,
          2,
        );

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(roomVersion: 4, previousRoomVersion: 3),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final state = container.read(groupListeningSessionControllerProvider);
        expect(state.snapshotRequired, isTrue);
        expect(state.failure?.code, GroupListeningErrorCode.snapshotRequired);
      },
    );

    test(
      'marks snapshot required on stale version transport failures',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
        );
        repository.connection = connection;

        final container = createContainer(repository: repository);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(
          GroupListeningConnectionWelcomeMessage(
            roomId: 'room-1',
            memberId: 'member-1',
            clientConnectionId: 'conn-1',
            roomVersion: 1,
            presenceVersion: 1,
            heartbeatInterval: const Duration(seconds: 10),
            memberStaleTimeout: const Duration(seconds: 45),
            serverTime: DateTime.utc(2026, 4, 21, 12),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        connection.add(
          const GroupListeningTransportErrorMessage(
            GroupListeningErrorState(
              code: GroupListeningErrorCode.staleVersion,
              message: 'room version is stale',
              retryable: true,
              roomVersion: 2,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final state = container.read(groupListeningSessionControllerProvider);
        expect(state.snapshotRequired, isTrue);
        expect(state.failure?.code, GroupListeningErrorCode.staleVersion);
        expect(state.status, GroupListeningSessionStatus.connected);
        expect(
          state.connection.status,
          GroupListeningConnectionStatus.connected,
        );
      },
    );

    test(
      'clears stored session when a snapshot fingerprint mismatches',
      () async {
        final repository = _FakeGroupListeningRepository();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
        );

        final container = createContainer(repository: repository);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );

        controller.applySnapshot(
          _roomState(fingerprint: 'other-fingerprint', roomVersion: 2),
        );
        await Future<void>.delayed(Duration.zero);

        final state = container.read(groupListeningSessionControllerProvider);
        final storedSession = await container
            .read(groupListeningSessionCredentialStoreProvider)
            .read();

        expect(state.status, GroupListeningSessionStatus.error);
        expect(
          state.failure?.code,
          GroupListeningErrorCode.fingerprintMismatch,
        );
        expect(state.room, isNull);
        expect(storedSession, isNull);
      },
    );

    test('clears stored session when reconnect fails fatally', () async {
      final repository = _FakeGroupListeningRepository();
      final fingerprint = computeSourceServerFingerprint(activeServer.url);
      repository.joinResponse = GroupListeningJoinResponse(
        runtimeContext: _runtimeContext(fingerprint: fingerprint),
        roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
      );
      repository.rejoinError = const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.fingerprintMismatch,
          message: 'fingerprint mismatch',
        ),
      );

      final container = createContainer(repository: repository);
      final controller = container.read(
        groupListeningSessionControllerProvider.notifier,
      );
      await controller.joinRoom(
        inviteCode: 'INVITE',
        client: client,
        connectAfterJoin: false,
      );

      await controller.reconnect();

      final state = container.read(groupListeningSessionControllerProvider);
      final storedSession = await container
          .read(groupListeningSessionCredentialStoreProvider)
          .read();

      expect(state.failure?.code, GroupListeningErrorCode.fingerprintMismatch);
      expect(storedSession, isNull);
    });
  });
}

GroupListeningSessionRuntimeContext _runtimeContext({
  required String fingerprint,
}) {
  return GroupListeningSessionRuntimeContext(
    roomId: 'room-1',
    memberId: 'member-1',
    role: GroupListeningMemberRole.host,
    authVersion: 1,
    voyageBaseUrl: Uri.parse('https://voyage.example.com'),
    sourceServerFingerprint: fingerprint,
    accessToken: 'access-token',
    accessTokenExpiresAt: DateTime.utc(2026, 4, 21, 13),
    rejoinToken: 'rejoin-token',
  );
}

GroupListeningRoomState _roomState({
  required String fingerprint,
  required int roomVersion,
}) {
  final joinedAt = DateTime.utc(2026, 4, 21, 12);
  return GroupListeningRoomState(
    protocolVersion: voyageProtocolVersion,
    roomId: 'room-1',
    roomStatus: GroupListeningRoomStatus.active,
    roomVersion: roomVersion,
    presenceVersion: 1,
    authVersion: 1,
    serverTime: joinedAt,
    sourceServerFingerprint: fingerprint,
    hostMemberId: 'member-1',
    self: const GroupListeningSelfState(
      memberId: 'member-1',
      role: GroupListeningMemberRole.host,
      canControl: true,
      authVersion: 1,
    ),
    members: <GroupListeningMemberState>[
      GroupListeningMemberState(
        memberId: 'member-1',
        displayName: 'Alice',
        deviceLabel: 'Desktop',
        role: GroupListeningMemberRole.host,
        presenceState: GroupListeningMemberPresenceState.active,
        capabilities: const <String>{'playback_anchor'},
        joinedAt: joinedAt,
        lastSeenAt: joinedAt,
      ),
    ],
    queue: GroupListeningQueueState(
      queueVersion: roomVersion,
      currentIndex: 0,
      entries: <GroupListeningQueueEntry>[
        GroupListeningQueueEntry(
          queueEntryId: 'entry-1',
          songId: 'song-1',
          addedByMemberId: 'member-1',
          addedAt: joinedAt,
        ),
      ],
    ),
    playbackAnchor: GroupListeningPlaybackAnchor(
      roomVersion: roomVersion,
      queueVersion: roomVersion,
      currentIndex: 0,
      currentQueueEntryId: 'entry-1',
      currentSongId: 'song-1',
      playbackState: GroupListeningPlaybackStatus.paused,
      position: const Duration(seconds: 15),
      capturedAt: joinedAt,
      playbackRate: 1,
      reason: GroupListeningPlaybackAnchorReason.snapshot,
      issuedByMemberId: 'member-1',
    ),
  );
}

GroupListeningRoomEvent _roomEvent({
  required int roomVersion,
  required int previousRoomVersion,
}) {
  final eventTime = DateTime.utc(2026, 4, 21, 12, 0, roomVersion);
  return GroupListeningRoomEvent(
    eventId: 'event-$roomVersion',
    eventType: GroupListeningRoomEventType.seek,
    roomId: 'room-1',
    previousRoomVersion: previousRoomVersion,
    roomVersion: roomVersion,
    playbackAnchor: GroupListeningPlaybackAnchor(
      roomVersion: roomVersion,
      queueVersion: roomVersion,
      currentIndex: 0,
      currentQueueEntryId: 'entry-1',
      currentSongId: 'song-1',
      playbackState: GroupListeningPlaybackStatus.paused,
      position: Duration(seconds: 15 + roomVersion),
      capturedAt: eventTime,
      playbackRate: 1,
      reason: GroupListeningPlaybackAnchorReason.seek,
      issuedByMemberId: 'member-1',
    ),
    queue: GroupListeningQueueState(
      queueVersion: roomVersion,
      currentIndex: 0,
      entries: <GroupListeningQueueEntry>[
        GroupListeningQueueEntry(
          queueEntryId: 'entry-1',
          songId: 'song-1',
          addedByMemberId: 'member-1',
          addedAt: eventTime,
        ),
      ],
    ),
    members: <GroupListeningMemberState>[
      GroupListeningMemberState(
        memberId: 'member-1',
        displayName: 'Alice',
        deviceLabel: 'Desktop',
        role: GroupListeningMemberRole.host,
        presenceState: GroupListeningMemberPresenceState.active,
        capabilities: const <String>{'playback_anchor'},
        joinedAt: DateTime.utc(2026, 4, 21, 12),
        lastSeenAt: eventTime,
      ),
    ],
    authVersion: 1,
    presenceVersion: 1,
    self: const GroupListeningSelfState(
      memberId: 'member-1',
      role: GroupListeningMemberRole.host,
      canControl: true,
      authVersion: 1,
    ),
  );
}
