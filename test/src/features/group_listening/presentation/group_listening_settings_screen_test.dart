import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_screen.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/server_settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

class _MockSettingsRepository extends Mock implements SettingsRepository {}

class _FakeGroupListeningRepository implements GroupListeningRepository {
  GroupListeningCreateRoomRequest? lastCreateRequest;
  GroupListeningJoinRoomRequest? lastJoinRequest;
  String? lastJoinAvailableRoomId;
  GroupListeningSessionRuntimeContext? lastLeaveSession;
  GroupListeningSessionRuntimeContext? lastCloseSession;
  GroupListeningSessionRuntimeContext? lastRotateInviteSession;
  GroupListeningJoinResponse? createResponse;
  GroupListeningJoinResponse? joinResponse;
  GroupListeningRoomState? snapshotResponse;
  List<GroupListeningAvailableRoomSummary> availableRooms =
      const <GroupListeningAvailableRoomSummary>[];
  _FakeRealtimeConnection? connection;

  @override
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  ) async {
    return connection!;
  }

  @override
  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  ) async {
    lastCreateRequest = request;
    return createResponse!;
  }

  @override
  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  ) async {
    return availableRooms;
  }

  @override
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  ) async {
    return const GroupListeningCapabilityDiscovery(
      service: 'voyage',
      apiVersion: 'v1',
      supportedProtocolVersions: <String>[voyageProtocolVersion],
      latestProtocolVersion: voyageProtocolVersion,
      websocketPath: '/api/v1/rooms/ws',
      heartbeatInterval: Duration(seconds: 10),
      memberStaleTimeout: Duration(seconds: 45),
    );
  }

  @override
  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) async {
    return snapshotResponse!;
  }

  @override
  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
  }) async {
    lastJoinAvailableRoomId = roomId;
    return joinResponse!;
  }

  @override
  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  ) async {
    lastJoinRequest = request;
    return joinResponse!;
  }

  @override
  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) async {
    lastLeaveSession = session;
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
    return joinResponse!;
  }

  @override
  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) async {
    lastCloseSession = session;
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
    lastRotateInviteSession = session;
    return GroupListeningRotateInviteResponse(
      roomId: session.roomId,
      roomVersion: expectedRoomVersion ?? 0,
      inviteCode: 'ROTATED',
    );
  }
}

class _FakeRealtimeConnection implements GroupListeningRealtimeConnection {
  @override
  Stream<GroupListeningTransportMessage> get messages =>
      const Stream<GroupListeningTransportMessage>.empty();

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> send(GroupListeningOutboundTransportMessage message) async {}
}

const _activeServer = ServerConfigModel(
  url: 'https://example.com/navidrome',
  username: 'alice',
  password: 'secret',
  apiVersion: '1.16.1',
);

final _packageInfo = PackageInfo(
  appName: 'Navis',
  packageName: 'org.navis.app',
  version: '1.2.3',
  buildNumber: '42',
  buildSignature: '',
);

Future<void> _pumpScreen(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const GroupListeningSettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpRoomAction(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

GroupListeningJoinResponse _joinResponse({
  required GroupListeningMemberRole role,
  String? inviteCode,
}) {
  final fingerprint = computeSourceServerFingerprint(_activeServer.url);
  final now = DateTime.utc(2026, 4, 21, 12);
  final selfMemberId = role == GroupListeningMemberRole.host
      ? 'member-1'
      : 'member-2';
  final hostMemberId = 'member-1';
  return GroupListeningJoinResponse(
    runtimeContext: GroupListeningSessionRuntimeContext(
      roomId: 'room-1',
      memberId: selfMemberId,
      role: role,
      authVersion: 1,
      voyageBaseUrl: Uri.parse('https://voyage.example.com'),
      sourceServerFingerprint: fingerprint,
      accessToken: 'token',
      accessTokenExpiresAt: now.add(const Duration(hours: 1)),
      rejoinToken: 'rejoin',
    ),
    roomSnapshot: GroupListeningRoomState(
      protocolVersion: voyageProtocolVersion,
      roomId: 'room-1',
      roomStatus: GroupListeningRoomStatus.active,
      roomVersion: 1,
      presenceVersion: 1,
      authVersion: 1,
      serverTime: now,
      sourceServerFingerprint: fingerprint,
      hostMemberId: hostMemberId,
      self: GroupListeningSelfState(
        memberId: selfMemberId,
        role: role,
        canControl: role == GroupListeningMemberRole.host,
        authVersion: 1,
      ),
      members: <GroupListeningMemberState>[
        GroupListeningMemberState(
          memberId: 'member-1',
          displayName: 'Alice',
          deviceLabel: 'Desktop',
          role: GroupListeningMemberRole.host,
          presenceState: GroupListeningMemberPresenceState.active,
          joinedAt: now,
          lastSeenAt: now,
        ),
        GroupListeningMemberState(
          memberId: 'member-2',
          displayName: 'Bob',
          deviceLabel: 'Phone',
          role: GroupListeningMemberRole.member,
          presenceState: GroupListeningMemberPresenceState.active,
          joinedAt: now.add(const Duration(seconds: 2)),
          lastSeenAt: now.add(const Duration(seconds: 2)),
        ),
      ],
      queue: GroupListeningQueueState(
        queueVersion: 1,
        currentIndex: 0,
        entries: <GroupListeningQueueEntry>[
          GroupListeningQueueEntry(
            queueEntryId: 'entry-1',
            songId: 'song-1',
            addedByMemberId: 'member-1',
            addedAt: now,
          ),
        ],
      ),
      playbackAnchor: GroupListeningPlaybackAnchor(
        roomVersion: 1,
        queueVersion: 1,
        currentIndex: 0,
        currentQueueEntryId: 'entry-1',
        currentSongId: 'song-1',
        playbackState: GroupListeningPlaybackStatus.playing,
        position: const Duration(seconds: 30),
        capturedAt: now,
        playbackRate: 1,
        reason: GroupListeningPlaybackAnchorReason.snapshot,
        issuedByMemberId: hostMemberId,
      ),
    ),
    inviteCode: inviteCode,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(const AppSettingsModel.defaults());
  });

  testWidgets('autosaves Listen Together enablement and Voyage URL', (
    tester,
  ) async {
    final repository = _MockSettingsRepository();
    AppSettingsModel? savedModel;

    when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
      savedModel = invocation.positionalArguments.first as AppSettingsModel;
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData<ServerConfigModel?>(_activeServer),
          ),
          lastFmBundledKeyProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ServerSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final enableSwitch = find.widgetWithText(
      SwitchListTile,
      'Enable Listen Together',
    );
    await tester.scrollUntilVisible(
      enableSwitch,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(enableSwitch);
    await tester.pumpAndSettle();

    final voyageServerField = find.byKey(
      const ValueKey('groupListeningVoyageServerUrlField'),
    );

    await tester.scrollUntilVisible(
      voyageServerField,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(voyageServerField, 'https://voyage.example.com');
    await tester.pump();

    verify(() => repository.saveSettings(any())).called(greaterThan(0));
    expect(savedModel, isNotNull);
    expect(savedModel!.groupListeningEnabled, isTrue);
    expect(savedModel!.voyageServerUrl, 'https://voyage.example.com');
    expect(savedModel!.voyageDisplayName, isNull);
    expect(savedModel!.voyageDeviceLabel, isNull);
    expect(savedModel!.voyageAutoFollowHost, isTrue);
    expect(savedModel!.audioMuseApiKey, isNull);
  });

  testWidgets('uses bundled Voyage servers when more than one is available', (
    tester,
  ) async {
    final repository = _MockSettingsRepository();
    AppSettingsModel? savedModel;

    when(() => repository.saveSettings(any())).thenAnswer((invocation) async {
      savedModel = invocation.positionalArguments.first as AppSettingsModel;
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          groupListeningBundledVoyageServersProvider.overrideWithValue(
            const <GroupListeningVoyageServerOption>[
              GroupListeningVoyageServerOption(
                label: 'Primary Voyage',
                url: 'https://voyage-1.example.com',
              ),
              GroupListeningVoyageServerOption(
                label: 'Backup Voyage',
                url: 'https://voyage-2.example.com',
              ),
            ],
          ),
          groupListeningVoyageConnectionStatusProvider.overrideWithValue(
            const GroupListeningVoyageConnectionStatus(
              state: GroupListeningVoyageConnectionState.disabled,
              message: 'Enable Listen Together to connect to Voyage.',
            ),
          ),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData<ServerConfigModel?>(_activeServer),
          ),
          lastFmBundledKeyProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ServerSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('groupListeningVoyageServerUrlField')),
      findsNothing,
    );

    final voyageDropdown = find.byKey(
      const ValueKey('groupListeningVoyageServerDropdown'),
    );
    await tester.scrollUntilVisible(
      voyageDropdown,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(voyageDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backup Voyage').last);
    await tester.pumpAndSettle();

    verify(() => repository.saveSettings(any())).called(greaterThan(0));
    expect(savedModel, isNotNull);
    expect(savedModel!.voyageServerUrl, 'https://voyage-2.example.com');
  });

  testWidgets(
    'shows disabled room messaging until group listening is enabled',
    (tester) async {
      await _pumpScreen(
        tester,
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          packageInfoProvider.overrideWithValue(
            AsyncData<PackageInfo>(_packageInfo),
          ),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData<ServerConfigModel?>(_activeServer),
          ),
        ],
      );

      expect(find.text('Listen Together is off'), findsOneWidget);
      expect(
        find.text(
          'Turn on Listen Together in configuration before creating or joining rooms.',
        ),
        findsWidgets,
      );

      final createButton = tester.widget<FilledButton>(
        find.byKey(const ValueKey('groupListeningCreateRoomButton')),
      );
      expect(createButton.onPressed, isNull);
    },
  );

  testWidgets('creates a room with an automatic device label', (
    tester,
  ) async {
    final repository = _FakeGroupListeningRepository()
      ..createResponse = _joinResponse(
        role: GroupListeningMemberRole.host,
        inviteCode: 'INVITE-123',
      )
      ..joinResponse = _joinResponse(role: GroupListeningMemberRole.member)
      ..snapshotResponse = _joinResponse(
        role: GroupListeningMemberRole.host,
      ).roomSnapshot
      ..connection = _FakeRealtimeConnection();

    await _pumpScreen(
      tester,
      overrides: [
        appSettingsProvider.overrideWithValue(
          AsyncData(
            AppSettingsModel.defaults().copyWith(
              groupListeningEnabled: true,
              voyageServerUrl: 'https://voyage.example.com',
              voyageDeviceLabel: 'Desktop',
              clearVoyageDisplayName: true,
            ),
          ),
        ),
        packageInfoProvider.overrideWithValue(
          AsyncData<PackageInfo>(_packageInfo),
        ),
        serverConfigStateProvider.overrideWithValue(
          const AsyncData<ServerConfigModel?>(_activeServer),
        ),
        groupListeningRepositoryProvider.overrideWithValue(repository),
      ],
    );

    await tester.tap(
      find.byKey(const ValueKey('groupListeningCreateRoomButton')),
    );
    await _pumpRoomAction(tester);

    expect(repository.lastCreateRequest, isNotNull);
    expect(repository.lastCreateRequest!.client.appVersion, '1.2.3');
    expect(repository.lastCreateRequest!.client.deviceLabel, isNotEmpty);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(GroupListeningSettingsScreen)),
    );
    expect(
      container.read(groupListeningSessionControllerProvider).activeInviteCode,
      'INVITE-123',
    );
    expect(find.text('Invite listeners'), findsOneWidget);
    expect(find.text('INVITE-123'), findsOneWidget);
  });

  testWidgets('joins a room with an invite code from the inline controls', (
    tester,
  ) async {
    final repository = _FakeGroupListeningRepository()
      ..createResponse = _joinResponse(role: GroupListeningMemberRole.host)
      ..joinResponse = _joinResponse(role: GroupListeningMemberRole.member)
      ..snapshotResponse = _joinResponse(
        role: GroupListeningMemberRole.member,
      ).roomSnapshot
      ..connection = _FakeRealtimeConnection();

    await _pumpScreen(
      tester,
      overrides: [
        appSettingsProvider.overrideWithValue(
          AsyncData(
            AppSettingsModel.defaults().copyWith(
              groupListeningEnabled: true,
              voyageServerUrl: 'https://voyage.example.com',
              voyageDeviceLabel: 'Phone',
              clearVoyageDisplayName: true,
            ),
          ),
        ),
        packageInfoProvider.overrideWithValue(
          AsyncData<PackageInfo>(_packageInfo),
        ),
        serverConfigStateProvider.overrideWithValue(
          const AsyncData<ServerConfigModel?>(_activeServer),
        ),
        groupListeningRepositoryProvider.overrideWithValue(repository),
      ],
    );

    await tester.enterText(
      find.byKey(const ValueKey('groupListeningInviteCodeField')),
      'room-123',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('groupListeningJoinRoomButton')),
    );
    await _pumpRoomAction(tester);

    expect(repository.lastJoinRequest, isNotNull);
    expect(repository.lastJoinRequest!.inviteCode, 'room-123');
  });

  testWidgets('lists available rooms and joins by room id', (tester) async {
    final now = DateTime.utc(2026, 4, 21, 12);
    final repository = _FakeGroupListeningRepository()
      ..createResponse = _joinResponse(role: GroupListeningMemberRole.host)
      ..joinResponse = _joinResponse(role: GroupListeningMemberRole.member)
      ..snapshotResponse = _joinResponse(
        role: GroupListeningMemberRole.member,
      ).roomSnapshot
      ..connection = _FakeRealtimeConnection()
      ..availableRooms = <GroupListeningAvailableRoomSummary>[
        GroupListeningAvailableRoomSummary(
          roomId: 'room-public-1',
          hostDisplayName: 'Alice',
          membersTotal: 2,
          activeMembers: 2,
          queueLength: 5,
          roomVersion: 3,
          lastActivityAt: now,
        ),
      ];

    await _pumpScreen(
      tester,
      overrides: [
        appSettingsProvider.overrideWithValue(
          AsyncData(
            AppSettingsModel.defaults().copyWith(
              groupListeningEnabled: true,
              voyageServerUrl: 'https://voyage.example.com',
              clearVoyageDisplayName: true,
            ),
          ),
        ),
        packageInfoProvider.overrideWithValue(
          AsyncData<PackageInfo>(_packageInfo),
        ),
        serverConfigStateProvider.overrideWithValue(
          const AsyncData<ServerConfigModel?>(_activeServer),
        ),
        groupListeningRepositoryProvider.overrideWithValue(repository),
      ],
    );

    expect(find.text('Available rooms'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);

    final availableRoomJoinButton = find.widgetWithText(FilledButton, 'Join');
    await tester.ensureVisible(availableRoomJoinButton);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await tester.pump();
    await tester.tap(availableRoomJoinButton);
    await _pumpRoomAction(tester);

    expect(repository.lastJoinAvailableRoomId, 'room-public-1');
    expect(repository.lastJoinRequest, isNull);
  });
}
