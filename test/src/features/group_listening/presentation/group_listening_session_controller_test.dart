import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _FakeGroupListeningRepository implements GroupListeningRepository {
  GroupListeningCapabilityDiscovery discovery =
      const GroupListeningCapabilityDiscovery(
        service: 'voyage',
        apiVersion: 'v1',
        serverVersion: '1.0.0',
        buildCommit: 'test',
        buildTime: 'test',
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
  final discoveriesByUrl = <String, GroupListeningCapabilityDiscovery>{};
  final discoveredUrls = <String>[];

  Object? joinError;
  Object? createError;
  Object? rejoinError;
  Object? connectError;
  Object? snapshotError;
  Object? leaveError;
  Object? closeError;
  Object? rotateInviteError;
  int connectCalls = 0;
  GroupListeningTransportConnectRequest? lastConnectRequest;
  int leaveCalls = 0;
  int rejoinCalls = 0;
  int snapshotCalls = 0;
  Completer<GroupListeningRoomState>? snapshotCompleter;
  Future<void> Function()? onLeaveRoom;
  Future<void> Function()? onCloseRoom;

  @override
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  ) async {
    connectCalls++;
    lastConnectRequest = request;
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
    final url = configuration.voyageBaseUrl.toString();
    discoveredUrls.add(url);
    return discoveriesByUrl[url] ?? discovery;
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
    String? pinCode,
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
    snapshotCalls++;
    final completer = snapshotCompleter;
    if (completer != null) {
      return completer.future;
    }
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
    leaveCalls++;
    await onLeaveRoom?.call();
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
    rejoinCalls++;
    if (rejoinError != null) {
      throw rejoinError!;
    }
    return rejoinResponse!;
  }

  @override
  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) async {
    await onCloseRoom?.call();
    if (closeError != null) {
      throw closeError!;
    }
    return GroupListeningCloseRoomResponse(
      roomId: session.roomId,
      roomStatus: GroupListeningRoomStatus.closed,
      roomVersion: (expectedRoomVersion ?? 0) + 1,
      closedAt: DateTime.utc(2026, 4, 21, 12),
    );
  }

  @override
  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) async {
    if (rotateInviteError != null) {
      throw rotateInviteError!;
    }
    return GroupListeningRotateInviteResponse(
      roomId: session.roomId,
      roomVersion: expectedRoomVersion ?? 0,
      inviteCode: 'ROTATED',
    );
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
    List<GroupListeningVoyageServerOption> bundledServers =
        const <GroupListeningVoyageServerOption>[],
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
        groupListeningBundledVoyageServersProvider.overrideWithValue(
          bundledServers,
        ),
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

    test('discovers highest compatible bundled Voyage server', () async {
      final repository = _FakeGroupListeningRepository();
      repository.discoveriesByUrl.addAll(
        <String, GroupListeningCapabilityDiscovery>{
          'https://voyage-1.example.com':
              const GroupListeningCapabilityDiscovery(
                service: 'voyage',
                apiVersion: 'v1',
                serverVersion: '1.2.0',
                buildCommit: 'one',
                buildTime: 'test',
                supportedProtocolVersions: <String>[voyageProtocolVersion],
                latestProtocolVersion: voyageProtocolVersion,
                websocketPath: '/api/v1/rooms/ws',
                heartbeatInterval: Duration(seconds: 10),
                memberStaleTimeout: Duration(seconds: 45),
              ),
          'https://voyage-2.example.com':
              const GroupListeningCapabilityDiscovery(
                service: 'voyage',
                apiVersion: 'v1',
                serverVersion: '1.3.0',
                buildCommit: 'two',
                buildTime: 'test',
                supportedProtocolVersions: <String>[voyageProtocolVersion],
                latestProtocolVersion: voyageProtocolVersion,
                websocketPath: '/api/v1/rooms/ws',
                heartbeatInterval: Duration(seconds: 10),
                memberStaleTimeout: Duration(seconds: 45),
              ),
          'https://voyage-3.example.com':
              const GroupListeningCapabilityDiscovery(
                service: 'voyage',
                apiVersion: 'v1',
                serverVersion: '2.0.0',
                buildCommit: 'three',
                buildTime: 'test',
                supportedProtocolVersions: <String>[voyageProtocolVersion],
                latestProtocolVersion: 'voyage-sync.v2',
                websocketPath: '/api/v1/rooms/ws',
                heartbeatInterval: Duration(seconds: 10),
                memberStaleTimeout: Duration(seconds: 45),
              ),
        },
      );
      final container = createContainer(
        repository: repository,
        settings: AppSettingsModel.defaults().copyWith(
          groupListeningEnabled: true,
          voyageServerUrl: 'https://voyage-1.example.com',
        ),
        bundledServers: const <GroupListeningVoyageServerOption>[
          GroupListeningVoyageServerOption(
            label: 'One',
            url: 'https://voyage-1.example.com',
          ),
          GroupListeningVoyageServerOption(
            label: 'Two',
            url: 'https://voyage-2.example.com',
          ),
          GroupListeningVoyageServerOption(
            label: 'Three',
            url: 'https://voyage-3.example.com',
          ),
        ],
      );

      final discovery = await container
          .read(groupListeningSessionControllerProvider.notifier)
          .discoverCapabilities();

      expect(discovery.serverVersion, '1.3.0');
      expect(
        repository.discoveredUrls,
        contains('https://voyage-1.example.com'),
      );
      expect(
        repository.discoveredUrls,
        contains('https://voyage-2.example.com'),
      );
      expect(
        repository.discoveredUrls,
        contains('https://voyage-3.example.com'),
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

    test('connects with stored v2alpha1 replay cursor state', () async {
      final repository = _FakeGroupListeningRepository();
      final connection = _FakeRealtimeConnection();
      final fingerprint = computeSourceServerFingerprint(activeServer.url);
      repository.discovery = const GroupListeningCapabilityDiscovery(
        service: 'voyage',
        apiVersion: 'v1',
        serverVersion: '1.0.0',
        buildCommit: 'test',
        buildTime: 'test',
        supportedProtocolVersions: <String>[voyageProtocolVersion],
        latestProtocolVersion: voyageProtocolVersion,
        websocketPath: '/api/v1/rooms/ws',
        heartbeatInterval: Duration(seconds: 10),
        memberStaleTimeout: Duration(seconds: 45),
        capabilities: <String>{voyageReplayResumeCapability},
      );
      repository.joinResponse = GroupListeningJoinResponse(
        runtimeContext: _runtimeContext(
          fingerprint: fingerprint,
          protocolVersion: voyageProtocolVersion,
        ),
        roomSnapshot: _roomState(
          fingerprint: fingerprint,
          roomVersion: 3,
          latestEventId: 7,
          protocolVersion: voyageProtocolVersion,
        ),
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

      final request = repository.lastConnectRequest;
      expect(request, isNotNull);
      expect(request!.session.protocolVersion, voyageProtocolVersion);
      expect(request.lastAppliedRoomVersion, 3);
      expect(request.lastAppliedEventId, 7);
      expect(request.lastAppliedQueueVersion, 3);
      expect(request.lastAppliedPresenceVersion, 1);
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

    test('uses event cursors as the v2alpha1 replay ordering signal', () async {
      final repository = _FakeGroupListeningRepository();
      final fingerprint = computeSourceServerFingerprint(activeServer.url);
      repository.joinResponse = GroupListeningJoinResponse(
        runtimeContext: _runtimeContext(
          fingerprint: fingerprint,
          protocolVersion: voyageProtocolVersion,
        ),
        roomSnapshot: _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          latestEventId: 10,
          protocolVersion: voyageProtocolVersion,
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

      controller.applyRealtimeEvent(
        _roomEvent(
          roomVersion: 5,
          previousRoomVersion: 4,
          eventCursor: 11,
        ),
      );

      final state = container.read(groupListeningSessionControllerProvider);
      expect(state.snapshotRequired, isFalse);
      expect(state.lastAppliedEventId, 11);
      expect(state.lastAppliedRoomVersion, 5);
    });

    test('ignores duplicate v2alpha1 replay events by event cursor', () async {
      final repository = _FakeGroupListeningRepository();
      final fingerprint = computeSourceServerFingerprint(activeServer.url);
      repository.joinResponse = GroupListeningJoinResponse(
        runtimeContext: _runtimeContext(
          fingerprint: fingerprint,
          protocolVersion: voyageProtocolVersion,
        ),
        roomSnapshot: _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          latestEventId: 10,
          protocolVersion: voyageProtocolVersion,
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

      controller.applyRealtimeEvent(
        _roomEvent(
          roomVersion: 2,
          previousRoomVersion: 1,
          eventCursor: 10,
        ),
      );

      final state = container.read(groupListeningSessionControllerProvider);
      expect(state.snapshotRequired, isFalse);
      expect(state.lastAppliedEventId, 10);
      expect(state.lastAppliedRoomVersion, 1);
    });

    test(
      'marks snapshot required when a v2alpha1 event cursor gap appears',
      () async {
        final repository = _FakeGroupListeningRepository();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(
            fingerprint: fingerprint,
            protocolVersion: voyageProtocolVersion,
          ),
          roomSnapshot: _roomState(
            fingerprint: fingerprint,
            roomVersion: 1,
            latestEventId: 10,
            protocolVersion: voyageProtocolVersion,
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

        controller.applyRealtimeEvent(
          _roomEvent(
            roomVersion: 2,
            previousRoomVersion: 1,
            eventCursor: 12,
          ),
        );

        final state = container.read(groupListeningSessionControllerProvider);
        expect(state.snapshotRequired, isTrue);
        expect(state.failure?.code, GroupListeningErrorCode.snapshotRequired);
        expect(state.failure!.details['last_applied_event_id'], 10);
        expect(state.failure!.details['incoming_event_id'], 12);
      },
    );

    test('keeps playback control after host transfer events', () async {
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
      controller.applyRealtimeEvent(
        GroupListeningRoomEvent(
          eventId: 'event-2',
          eventType: GroupListeningRoomEventType.transferHost,
          roomId: 'room-1',
          previousRoomVersion: 1,
          roomVersion: 2,
          hostMemberId: 'member-2',
          members: <GroupListeningMemberState>[
            _member('member-1', GroupListeningMemberRole.member),
            _member('member-2', GroupListeningMemberRole.host),
          ],
          authVersion: 1,
          presenceVersion: 1,
        ),
      );

      final state = container.read(groupListeningSessionControllerProvider);
      expect(state.room?.self.role, GroupListeningMemberRole.member);
      expect(state.room?.self.canControl, isTrue);
    });

    test(
      'applies explicit removed member ids on combined leave and host transfer',
      () async {
        final repository = _FakeGroupListeningRepository();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(
            fingerprint: fingerprint,
            role: GroupListeningMemberRole.member,
          ),
          roomSnapshot: _roomState(
            fingerprint: fingerprint,
            roomVersion: 1,
            selfRole: GroupListeningMemberRole.member,
            selfCanControl: true,
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
        controller.applyRealtimeEvent(
          GroupListeningRoomEvent(
            eventId: 'event-2',
            eventType: GroupListeningRoomEventType.memberLeft,
            roomId: 'room-1',
            previousRoomVersion: 1,
            roomVersion: 2,
            hostMemberId: 'member-2',
            members: <GroupListeningMemberState>[
              _member('member-1', GroupListeningMemberRole.member),
              _member('member-2', GroupListeningMemberRole.host),
            ],
            removedMemberIds: const <String>['member-1'],
            authVersion: 1,
            presenceVersion: 1,
          ),
        );

        final state = container.read(groupListeningSessionControllerProvider);
        expect(state.room?.hostMemberId, 'member-2');
        expect(
          state.room?.members.map((member) => member.memberId).toList(),
          isNot(contains('member-1')),
        );
      },
    );

    test(
      'keeps room admin actions host-only for collaborative members',
      () async {
        final repository = _FakeGroupListeningRepository();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(
            fingerprint: fingerprint,
            role: GroupListeningMemberRole.member,
          ),
          roomSnapshot: _roomState(
            fingerprint: fingerprint,
            roomVersion: 1,
            selfRole: GroupListeningMemberRole.member,
            selfCanControl: true,
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
        await controller.closeRoom();

        final state = container.read(groupListeningSessionControllerProvider);
        expect(state.failure?.code, GroupListeningErrorCode.forbidden);
      },
    );

    test(
      'retries leave after rejoining when Voyage does not confirm the first leave',
      () async {
        final repository = _FakeGroupListeningRepository();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final session = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
        );
        repository.joinResponse = session;
        repository.rejoinResponse = session;
        repository.onLeaveRoom = () async {
          if (repository.leaveCalls == 1) {
            repository.leaveError = const GroupListeningRepositoryException(
              GroupListeningErrorState(
                code: GroupListeningErrorCode.transportUnavailable,
                message: 'Unable to leave Voyage room cleanly.',
                retryable: true,
              ),
            );
            return;
          }
          repository.leaveError = null;
        };

        final container = createContainer(repository: repository);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.leaveRoom();

        final state = container.read(groupListeningSessionControllerProvider);
        final storedSession = await container
            .read(groupListeningSessionCredentialStoreProvider)
            .read();
        expect(repository.leaveCalls, 2);
        expect(repository.rejoinCalls, 1);
        expect(state.status, GroupListeningSessionStatus.idle);
        expect(state.room, isNull);
        expect(state.failure, isNull);
        expect(storedSession, isNull);
      },
    );

    test(
      'cleans up locally when Voyage still does not confirm leave after a retry',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final session = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
        );
        repository.joinResponse = session;
        repository.rejoinResponse = session;
        repository.connection = connection;
        repository.onLeaveRoom = () async {
          connection.add(
            const GroupListeningTransportDisconnectedMessage(
              error: GroupListeningErrorState(
                code: GroupListeningErrorCode.transportDisconnected,
                message: 'Voyage realtime transport disconnected.',
                retryable: true,
              ),
              retryable: true,
            ),
          );
          await Future<void>.delayed(Duration.zero);
        };
        repository.leaveError = const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.transportUnavailable,
            message: 'Unable to leave Voyage room cleanly.',
            retryable: true,
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

        await controller.leaveRoom();

        final state = container.read(groupListeningSessionControllerProvider);
        final storedSession = await container
            .read(groupListeningSessionCredentialStoreProvider)
            .read();
        expect(repository.leaveCalls, 2);
        expect(repository.rejoinCalls, 1);
        expect(state.status, GroupListeningSessionStatus.idle);
        expect(state.room, isNull);
        expect(state.failure, isNull);
        expect(storedSession, isNull);
        expect(connection.disconnected, isTrue);
      },
    );

    test('sends transfer_host mutations for host users', () async {
      final repository = _FakeGroupListeningRepository();
      final connection = _FakeRealtimeConnection();
      final fingerprint = computeSourceServerFingerprint(activeServer.url);
      repository.joinResponse = GroupListeningJoinResponse(
        runtimeContext: _runtimeContext(fingerprint: fingerprint),
        roomSnapshot:
            _roomState(
              fingerprint: fingerprint,
              roomVersion: 1,
            ).copyWith(
              members: <GroupListeningMemberState>[
                _member('member-1', GroupListeningMemberRole.host),
                _member('member-2', GroupListeningMemberRole.member),
              ],
            ),
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

      final mutationId = await controller.transferHost(
        targetMemberId: 'member-2',
        source: 'settings-ui',
      );

      expect(mutationId, isNotNull);
      expect(connection.sentMessages, hasLength(1));
      final message =
          connection.sentMessages.single as GroupListeningMutationMessage;
      expect(message.type, GroupListeningMutationType.transferHost);
      expect(message.targetMemberId, 'member-2');
      expect(message.expectedQueueVersion, isNull);
      expect(message.expectedPlaybackVersion, isNull);
    });

    test('sends domain base versions with playback track changes', () async {
      final repository = _FakeGroupListeningRepository();
      final connection = _FakeRealtimeConnection();
      final fingerprint = computeSourceServerFingerprint(activeServer.url);
      repository.joinResponse = GroupListeningJoinResponse(
        runtimeContext: _runtimeContext(fingerprint: fingerprint),
        roomSnapshot: _roomState(
          fingerprint: fingerprint,
          roomVersion: 9,
        ).copyWith(playbackVersion: 4),
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
          roomVersion: 9,
          presenceVersion: 1,
          heartbeatInterval: const Duration(seconds: 10),
          memberStaleTimeout: const Duration(seconds: 45),
          serverTime: DateTime.utc(2026, 4, 21, 12),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final mutationId = await controller.sendMutation(
        type: GroupListeningMutationType.playbackAnchor,
        playbackAnchor: GroupListeningPlaybackAnchor(
          roomVersion: 9,
          queueVersion: 9,
          currentIndex: 0,
          currentQueueEntryId: 'entry-1',
          currentSongId: 'song-1',
          playbackState: GroupListeningPlaybackStatus.paused,
          position: Duration.zero,
          capturedAt: DateTime.utc(2026, 4, 21, 12),
          playbackRate: 1,
          reason: GroupListeningPlaybackAnchorReason.trackChange,
          issuedByMemberId: 'member-1',
        ),
      );

      expect(mutationId, isNotNull);
      final message =
          connection.sentMessages.single as GroupListeningMutationMessage;
      expect(message.expectedQueueVersion, 9);
      expect(message.expectedPlaybackVersion, 4);
    });

    test(
      'rejects transfer_host when the target member is no longer present',
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

        final mutationId = await controller.transferHost(
          targetMemberId: 'member-2',
          source: 'settings-ui',
        );

        final state = container.read(groupListeningSessionControllerProvider);
        expect(mutationId, isNull);
        expect(connection.sentMessages, isEmpty);
        expect(state.failure?.code, GroupListeningErrorCode.validationFailed);
      },
    );

    test(
      'rejects transfer_host when the target member is not active',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot:
              _roomState(
                fingerprint: fingerprint,
                roomVersion: 1,
              ).copyWith(
                members: <GroupListeningMemberState>[
                  _member('member-1', GroupListeningMemberRole.host),
                  _member('member-2', GroupListeningMemberRole.member).copyWith(
                    presenceState: GroupListeningMemberPresenceState.stale,
                  ),
                ],
              ),
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

        final mutationId = await controller.transferHost(
          targetMemberId: 'member-2',
          source: 'settings-ui',
        );

        final state = container.read(groupListeningSessionControllerProvider);
        expect(mutationId, isNull);
        expect(connection.sentMessages, isEmpty);
        expect(state.failure?.code, GroupListeningErrorCode.validationFailed);
      },
    );

    test(
      'keeps auto-reconnecting after a retryable reconnect transport failure',
      () async {
        final repository = _FakeGroupListeningRepository();
        final initialConnection = _FakeRealtimeConnection();
        final recoveredConnection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final rejoinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
        );
        repository.joinResponse = rejoinResponse;
        repository.rejoinResponse = rejoinResponse;
        repository.connection = initialConnection;

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
        initialConnection.add(
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

        repository.connectError = const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.transportUnavailable,
            message: 'Unable to connect to Voyage realtime transport.',
            retryable: true,
          ),
        );
        initialConnection.add(
          const GroupListeningTransportDisconnectedMessage(
            error: GroupListeningErrorState(
              code: GroupListeningErrorCode.transportDisconnected,
              message: 'Voyage realtime transport disconnected.',
              retryable: true,
            ),
            retryable: true,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 2200));

        expect(repository.connectCalls, 2);
        expect(
          container.read(groupListeningSessionControllerProvider).failure?.code,
          GroupListeningErrorCode.transportUnavailable,
        );

        repository.connectError = null;
        repository.connection = recoveredConnection;

        await Future<void>.delayed(const Duration(milliseconds: 4500));

        expect(repository.connectCalls, 3);

        recoveredConnection.add(
          GroupListeningConnectionWelcomeMessage(
            roomId: 'room-1',
            memberId: 'member-1',
            clientConnectionId: 'conn-2',
            roomVersion: 1,
            presenceVersion: 1,
            heartbeatInterval: const Duration(seconds: 10),
            memberStaleTimeout: const Duration(seconds: 45),
            serverTime: DateTime.utc(2026, 4, 21, 12, 0, 7),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final state = container.read(groupListeningSessionControllerProvider);
        expect(state.status, GroupListeningSessionStatus.connected);
        expect(state.connection.isConnected, isTrue);
        expect(state.failure, isNull);
      },
    );

    test(
      'closes cleanly when transport teardown races with the close request',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
          inviteCode: 'INVITE',
        );
        repository.connection = connection;
        repository.onCloseRoom = () async {
          connection.add(
            const GroupListeningTransportDisconnectedMessage(
              error: GroupListeningErrorState(
                code: GroupListeningErrorCode.transportDisconnected,
                message: 'Voyage realtime transport disconnected.',
                retryable: true,
              ),
              retryable: true,
            ),
          );
          await Future<void>.delayed(Duration.zero);
        };
        repository.closeError = const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.transportUnavailable,
            message: 'Unable to close Voyage room cleanly.',
            retryable: true,
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

        await controller.closeRoom();

        final state = container.read(groupListeningSessionControllerProvider);
        final storedSession = await container
            .read(groupListeningSessionCredentialStoreProvider)
            .read();
        expect(state.status, GroupListeningSessionStatus.idle);
        expect(state.room?.roomStatus, GroupListeningRoomStatus.closed);
        expect(state.failure, isNull);
        expect(state.activeInviteCode, isNull);
        expect(storedSession, isNull);
        expect(connection.disconnected, isTrue);
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
      'marks snapshot required when heartbeat acks stay ahead of room state',
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
          GroupListeningHeartbeatAckMessage(
            roomVersion: 3,
            presenceVersion: 1,
            nextHeartbeatDeadline: DateTime.utc(2026, 4, 21, 12, 0, 10),
            serverTime: DateTime.utc(2026, 4, 21, 12, 0, 1),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 2200));

        final state = container.read(groupListeningSessionControllerProvider);
        expect(state.snapshotRequired, isTrue);
        expect(state.failure?.code, GroupListeningErrorCode.snapshotRequired);
        expect(state.failure?.roomVersion, 3);
      },
    );

    test(
      'cancels heartbeat-ack recovery when the missing room event arrives',
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
          GroupListeningHeartbeatAckMessage(
            roomVersion: 3,
            presenceVersion: 1,
            nextHeartbeatDeadline: DateTime.utc(2026, 4, 21, 12, 0, 10),
            serverTime: DateTime.utc(2026, 4, 21, 12, 0, 1),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(roomVersion: 2, previousRoomVersion: 1),
          ),
        );
        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(roomVersion: 3, previousRoomVersion: 2),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 2200));

        final state = container.read(groupListeningSessionControllerProvider);
        expect(state.snapshotRequired, isFalse);
        expect(state.lastAppliedRoomVersion, 3);
        expect(state.failure, isNull);
      },
    );

    test('coalesces overlapping snapshot refresh requests', () async {
      final repository = _FakeGroupListeningRepository();
      final fingerprint = computeSourceServerFingerprint(activeServer.url);
      final snapshotCompleter = Completer<GroupListeningRoomState>();
      repository.joinResponse = GroupListeningJoinResponse(
        runtimeContext: _runtimeContext(fingerprint: fingerprint),
        roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
      );
      repository.snapshotCompleter = snapshotCompleter;

      final container = createContainer(repository: repository);
      final controller = container.read(
        groupListeningSessionControllerProvider.notifier,
      );

      await controller.joinRoom(
        inviteCode: 'INVITE',
        client: client,
        connectAfterJoin: false,
      );

      final firstRefresh = controller.refreshSnapshot(reason: 'test-one');
      final secondRefresh = controller.refreshSnapshot(reason: 'test-two');
      await Future<void>.delayed(Duration.zero);

      expect(repository.snapshotCalls, 1);

      snapshotCompleter.complete(
        _roomState(fingerprint: fingerprint, roomVersion: 2),
      );
      await Future.wait<void>([firstRefresh, secondRefresh]);

      final state = container.read(groupListeningSessionControllerProvider);
      expect(repository.snapshotCalls, 1);
      expect(state.lastAppliedRoomVersion, 2);
      expect(state.snapshotRequired, isFalse);
    });

    test('updates server clock offset from applied snapshots', () async {
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

      final snapshot = _roomState(fingerprint: fingerprint, roomVersion: 2);
      controller.applySnapshot(snapshot);

      final state = container.read(groupListeningSessionControllerProvider);
      final projectedServerNow = DateTime.now().toUtc().add(
        state.connection.serverClockOffset,
      );
      expect(
        projectedServerNow.difference(snapshot.serverTime).abs(),
        lessThan(const Duration(seconds: 1)),
      );
    });

    test(
      'cleans up locally when snapshot refresh is unauthorized while connected',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: _roomState(fingerprint: fingerprint, roomVersion: 1),
        );
        repository.connection = connection;
        repository.snapshotError = const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.unauthorized,
            message: 'invalid access token',
          ),
        );
        repository.rejoinError = const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.unauthorized,
            message: 'invalid rejoin token',
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

        await controller.refreshSnapshot(reason: 'test-unauthorized');

        final state = container.read(groupListeningSessionControllerProvider);
        final storedSession = await container
            .read(groupListeningSessionCredentialStoreProvider)
            .read();
        expect(state.status, GroupListeningSessionStatus.idle);
        expect(
          state.connection.status,
          GroupListeningConnectionStatus.disconnected,
        );
        expect(state.room, isNull);
        expect(state.failure?.code, GroupListeningErrorCode.unauthorized);
        expect(storedSession, isNull);
      },
    );

    test('cleans up locally when transport reports unauthorized', () async {
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
            code: GroupListeningErrorCode.unauthorized,
            message: 'invalid access token',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final state = container.read(groupListeningSessionControllerProvider);
      final storedSession = await container
          .read(groupListeningSessionCredentialStoreProvider)
          .read();
      expect(state.status, GroupListeningSessionStatus.idle);
      expect(
        state.connection.status,
        GroupListeningConnectionStatus.disconnected,
      );
      expect(state.room, isNull);
      expect(state.failure?.code, GroupListeningErrorCode.unauthorized);
      expect(storedSession, isNull);
    });

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
  GroupListeningMemberRole role = GroupListeningMemberRole.host,
  String protocolVersion = voyageProtocolVersion,
}) {
  final memberId = role == GroupListeningMemberRole.host
      ? 'member-1'
      : 'member-2';
  return GroupListeningSessionRuntimeContext(
    roomId: 'room-1',
    memberId: memberId,
    role: role,
    authVersion: 1,
    voyageBaseUrl: Uri.parse('https://voyage.example.com'),
    sourceServerFingerprint: fingerprint,
    accessToken: 'access-token',
    accessTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    rejoinToken: 'rejoin-token',
    protocolVersion: protocolVersion,
  );
}

GroupListeningRoomState _roomState({
  required String fingerprint,
  required int roomVersion,
  GroupListeningMemberRole selfRole = GroupListeningMemberRole.host,
  bool selfCanControl = true,
  int latestEventId = 0,
  String protocolVersion = voyageProtocolVersion,
}) {
  final joinedAt = DateTime.utc(2026, 4, 21, 12);
  final selfMemberId = selfRole == GroupListeningMemberRole.host
      ? 'member-1'
      : 'member-2';
  return GroupListeningRoomState(
    protocolVersion: protocolVersion,
    roomId: 'room-1',
    roomStatus: GroupListeningRoomStatus.active,
    roomVersion: roomVersion,
    latestEventId: latestEventId,
    presenceVersion: 1,
    authVersion: 1,
    serverTime: joinedAt,
    sourceServerFingerprint: fingerprint,
    hostMemberId: 'member-1',
    self: GroupListeningSelfState(
      memberId: selfMemberId,
      role: selfRole,
      canControl: selfCanControl,
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
      if (selfMemberId != 'member-1')
        GroupListeningMemberState(
          memberId: 'member-2',
          displayName: 'Bob',
          deviceLabel: 'Phone',
          role: GroupListeningMemberRole.member,
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
  int? eventCursor,
}) {
  final eventTime = DateTime.utc(2026, 4, 21, 12, 0, roomVersion);
  return GroupListeningRoomEvent(
    eventId: eventCursor?.toString() ?? 'event-$roomVersion',
    eventCursor: eventCursor,
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

GroupListeningMemberState _member(
  String memberId,
  GroupListeningMemberRole role,
) {
  return GroupListeningMemberState(
    memberId: memberId,
    displayName: memberId,
    deviceLabel: 'Desktop',
    role: role,
    presenceState: GroupListeningMemberPresenceState.active,
    capabilities: const <String>{'playback_anchor'},
    joinedAt: DateTime.utc(2026, 4, 21, 12),
    lastSeenAt: DateTime.utc(2026, 4, 21, 12),
  );
}
