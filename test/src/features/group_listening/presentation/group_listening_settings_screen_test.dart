import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
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

class _StaticGroupListeningSessionController
    extends GroupListeningSessionController {
  _StaticGroupListeningSessionController(this._state);

  final GroupListeningSessionState _state;

  @override
  GroupListeningSessionState build() => _state;
}

class _FakeGroupListeningRepository implements GroupListeningRepository {
  GroupListeningCreateRoomRequest? lastCreateRequest;
  GroupListeningJoinRoomRequest? lastJoinRequest;
  String? lastJoinAvailableRoomId;
  String? lastJoinAvailableRoomPin;
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
      serverVersion: '1.0.0',
      buildCommit: 'test',
      buildTime: 'test',
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
    String? pinCode,
  }) async {
    lastJoinAvailableRoomId = roomId;
    lastJoinAvailableRoomPin = pinCode;
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

const _validInviteCode = 'AbCdEfGhIjKlMnOpQrStUvWx';

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

Future<void> _pumpSheetHost(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showListenTogetherSheet(context),
              child: const Text('Open sheet'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _mockClipboardText(String? text) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.getData':
        return text == null ? null : <String, dynamic>{'text': text};
      case 'Clipboard.setData':
        return null;
      default:
        return null;
    }
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

GroupListeningJoinResponse _joinResponse({
  required GroupListeningMemberRole role,
  String? inviteCode,
  bool? canControl,
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
        canControl: canControl ?? true,
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

      final createButtonFinder = find.byKey(
        const ValueKey('groupListeningCreateRoomButton'),
      );
      await tester.scrollUntilVisible(
        createButtonFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final createButton = tester.widget<FilledButton>(
        createButtonFinder,
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

    final createRoomButton = find.byKey(
      const ValueKey('groupListeningCreateRoomButton'),
    );
    await tester.scrollUntilVisible(
      createRoomButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(createRoomButton);
    final createRoomAction = tester.widget<FilledButton>(createRoomButton);
    expect(createRoomAction.onPressed, isNotNull);
    createRoomAction.onPressed!.call();
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
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(find.text('Invite listeners'), findsOneWidget);
    expect(find.text('INVITE-123'), findsOneWidget);
  });

  testWidgets('joins a room with an invite code from the join-code modal', (
    tester,
  ) async {
    _mockClipboardText('not-an-invite');

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

    final joinWithCodeButton = find.byKey(
      const ValueKey('groupListeningJoinWithCodeButton'),
    );
    await tester.scrollUntilVisible(
      joinWithCodeButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(joinWithCodeButton);
    await tester.pumpAndSettle();
    final joinWithCodeAction = tester.widget<TextButton>(joinWithCodeButton);
    expect(joinWithCodeAction.onPressed, isNotNull);
    joinWithCodeAction.onPressed!.call();
    await _pumpRoomAction(tester);
    await tester.enterText(
      find.byKey(const ValueKey('groupListeningJoinWithCodeField')),
      'room-123',
    );
    await tester.tap(
      find.byKey(const ValueKey('groupListeningJoinWithCodeConfirmButton')),
    );
    await _pumpRoomAction(tester);

    expect(repository.lastJoinRequest, isNotNull);
    expect(repository.lastJoinRequest!.inviteCode, 'room-123');
  });

  testWidgets(
    'prefills the join-code modal from the clipboard when an invite is detected',
    (
      tester,
    ) async {
      _mockClipboardText(_validInviteCode);

      final repository = _FakeGroupListeningRepository()
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

      final joinWithCodeButton = find.byKey(
        const ValueKey('groupListeningJoinWithCodeButton'),
      );
      await tester.scrollUntilVisible(
        joinWithCodeButton,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(joinWithCodeButton);
      await tester.pumpAndSettle();
      final joinWithCodeAction = tester.widget<TextButton>(joinWithCodeButton);
      expect(joinWithCodeAction.onPressed, isNotNull);
      joinWithCodeAction.onPressed!.call();
      await _pumpRoomAction(tester);

      final inviteField = tester.widget<TextField>(
        find.byKey(const ValueKey('groupListeningJoinWithCodeField')),
      );
      expect(inviteField.controller?.text, _validInviteCode);
      expect(
        find.text('Detected an invite code from your clipboard.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'shows only PIN room setting before creating a room',
    (
      tester,
    ) async {
      final repository = _FakeGroupListeningRepository();

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

      final roomSettingsTitle = find.text('Room settings');
      final createRoomButton = find.byKey(
        const ValueKey('groupListeningCreateRoomButton'),
      );

      expect(roomSettingsTitle, findsOneWidget);
      expect(
        tester.getTopLeft(roomSettingsTitle).dy,
        lessThan(tester.getTopLeft(createRoomButton).dy),
      );

      final pinProtectedToggle = find.widgetWithText(
        SwitchListTile,
        'PIN Protected',
      );

      expect(find.text('Shotgun Mode'), findsNothing);
      expect(find.text('Host Only'), findsNothing);
      expect(pinProtectedToggle, findsOneWidget);
      expect(find.text('Require a 4-digit code to join.'), findsOneWidget);
      await tester.tap(pinProtectedToggle);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(pinProtectedToggle).value, isTrue);
      expect(
        find.byKey(const ValueKey('groupListeningRoomPinField')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('groupListeningRoomPinField')),
        '12ab34',
      );
      await tester.pumpAndSettle();

      final pinField = tester.widget<TextField>(
        find.byKey(const ValueKey('groupListeningRoomPinField')),
      );
      expect(pinField.controller?.text, '1234');
    },
  );

  testWidgets('creates collaborative room with PIN when creating a room', (
    tester,
  ) async {
    final repository = _FakeGroupListeningRepository()
      ..createResponse = _joinResponse(
        role: GroupListeningMemberRole.host,
        inviteCode: 'INVITE-123',
      )
      ..connection = _FakeRealtimeConnection();

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

    await tester.tap(
      find.widgetWithText(SwitchListTile, 'PIN Protected'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('groupListeningRoomPinField')),
      '2468',
    );
    await tester.tap(
      find.byKey(const ValueKey('groupListeningCreateRoomButton')),
    );
    await _pumpRoomAction(tester);

    expect(
      repository.lastCreateRequest?.roomOptions.roomMode,
      GroupListeningRoomMode.collaborative,
    );
    expect(repository.lastCreateRequest?.roomOptions.pinCode, '2468');
  });

  testWidgets(
    'shows collaborative playback for members without pre-room settings',
    (
      tester,
    ) async {
      final repository = _FakeGroupListeningRepository();
      final memberSession = _joinResponse(
        role: GroupListeningMemberRole.member,
        canControl: true,
      );
      final sessionState = GroupListeningSessionState(
        availability: GroupListeningAvailability.ready,
        status: GroupListeningSessionStatus.idle,
        connection: const GroupListeningConnectionState.disconnected(),
        room: memberSession.roomSnapshot,
        lastAppliedRoomVersion: memberSession.roomSnapshot.roomVersion,
      );

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
          groupListeningSessionControllerProvider.overrideWith(
            () => _StaticGroupListeningSessionController(sessionState),
          ),
          groupListeningRepositoryProvider.overrideWithValue(repository),
        ],
      );

      expect(find.text('Shared playback enabled'), findsOneWidget);
      expect(find.text('Room settings'), findsNothing);
      expect(
        find.byKey(const ValueKey('groupListeningCloseRoomButton')),
        findsNothing,
      );
      expect(find.text('Invite listeners'), findsNothing);
    },
  );

  testWidgets('shows an internal drag handle and dismisses the sheet on drag', (
    tester,
  ) async {
    final repository = _FakeGroupListeningRepository();

    await _pumpSheetHost(
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

    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();

    final dragHandle = find.byKey(
      const ValueKey('groupListeningSheetDragHandle'),
    );
    expect(dragHandle, findsOneWidget);

    await tester.fling(
      find.byKey(const ValueKey('groupListeningSheetHeader')),
      const Offset(0, 300),
      1200,
    );
    await tester.pumpAndSettle();

    expect(dragHandle, findsNothing);
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

    final availableRoomsTitle = find.text('Available rooms');
    await tester.scrollUntilVisible(
      availableRoomsTitle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(availableRoomsTitle, findsOneWidget);
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

  testWidgets('prompts for PIN before joining a locked listed room', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 4, 21, 12);
    final repository = _FakeGroupListeningRepository()
      ..joinResponse = _joinResponse(role: GroupListeningMemberRole.member)
      ..snapshotResponse = _joinResponse(
        role: GroupListeningMemberRole.member,
      ).roomSnapshot
      ..connection = _FakeRealtimeConnection()
      ..availableRooms = <GroupListeningAvailableRoomSummary>[
        GroupListeningAvailableRoomSummary(
          roomId: 'room-locked-1',
          hostDisplayName: 'Alice',
          roomMode: GroupListeningRoomMode.shotgun,
          requiresPin: true,
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

    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(find.textContaining('Shotgun'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Available rooms'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final joinButton = find.widgetWithText(FilledButton, 'Join');
    await tester.scrollUntilVisible(
      joinButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(joinButton);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('groupListeningAvailableRoomPinField')),
      '9876',
    );
    await tester.tap(
      find.byKey(const ValueKey('groupListeningAvailableRoomPinConfirmButton')),
    );
    await _pumpRoomAction(tester);

    expect(repository.lastJoinAvailableRoomId, 'room-locked-1');
    expect(repository.lastJoinAvailableRoomPin, '9876');
  });
}
