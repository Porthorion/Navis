import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_active_session_indicator.dart';

void main() {
  Future<void> pumpIndicator(
    WidgetTester tester,
    GroupListeningSessionState state,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupListeningActiveSessionIndicator(
            state: state,
            onTap: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('renders host indicator when the host is connected', (
    tester,
  ) async {
    await pumpIndicator(tester, _sessionState());

    expect(find.byIcon(Icons.headset_mic_outlined), findsOneWidget);
    expect(find.text('Group listening • Hosting'), findsOneWidget);
    expect(find.text('Connected • In sync • 2 in room'), findsOneWidget);
  });

  testWidgets('renders member indicator when a listener is connected', (
    tester,
  ) async {
    await pumpIndicator(
      tester,
      _sessionState(role: GroupListeningMemberRole.member),
    );

    expect(find.byIcon(Icons.people_alt_outlined), findsOneWidget);
    expect(find.text('Group listening • Listening'), findsOneWidget);
    expect(find.text('Connected • In sync • 2 in room'), findsOneWidget);
  });

  testWidgets(
    'renders warning state while reconnecting and awaiting a snapshot',
    (tester) async {
      await pumpIndicator(
        tester,
        _sessionState(
          snapshotRequired: true,
          connection: const GroupListeningConnectionState(
            status: GroupListeningConnectionStatus.reconnecting,
          ),
        ),
      );

      expect(find.byIcon(Icons.sync_problem_outlined), findsOneWidget);
      expect(find.textContaining('Reconnecting'), findsOneWidget);
      expect(find.textContaining('Snapshot required'), findsOneWidget);
    },
  );

  testWidgets('renders attention state after the transport disconnects', (
    tester,
  ) async {
    await pumpIndicator(
      tester,
      _sessionState(
        status: GroupListeningSessionStatus.error,
        connection: const GroupListeningConnectionState.disconnected(),
        failure: const GroupListeningErrorState(
          code: GroupListeningErrorCode.transportDisconnected,
          message: 'transport disconnected',
        ),
      ),
    );

    expect(find.byIcon(Icons.sync_problem_outlined), findsOneWidget);
    expect(find.textContaining('Needs attention'), findsOneWidget);
  });
}

GroupListeningSessionState _sessionState({
  GroupListeningMemberRole role = GroupListeningMemberRole.host,
  GroupListeningSessionStatus status = GroupListeningSessionStatus.connected,
  GroupListeningConnectionState connection =
      const GroupListeningConnectionState(
        status: GroupListeningConnectionStatus.connected,
      ),
  bool snapshotRequired = false,
  GroupListeningErrorState? failure,
}) {
  final joinedAt = DateTime.utc(2026, 4, 21, 12);
  return GroupListeningSessionState(
    availability: GroupListeningAvailability.ready,
    status: status,
    connection: connection,
    configuration: GroupListeningClientConfiguration(
      voyageBaseUrl: Uri.parse('https://voyage.example.com'),
      sourceServerOrigin: 'https://example.com',
      sourceServerFingerprint: 'fingerprint',
      displayName: 'alice',
      deviceLabel: 'Desktop',
      autoFollowHost: true,
    ),
    room: GroupListeningRoomState(
      protocolVersion: voyageProtocolVersion,
      roomId: 'room-1',
      roomStatus: GroupListeningRoomStatus.active,
      roomVersion: 1,
      presenceVersion: 1,
      authVersion: 1,
      serverTime: joinedAt,
      sourceServerFingerprint: 'fingerprint',
      hostMemberId: 'member-1',
      self: GroupListeningSelfState(
        memberId: role == GroupListeningMemberRole.host
            ? 'member-1'
            : 'member-2',
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
          joinedAt: joinedAt,
          lastSeenAt: joinedAt,
        ),
        GroupListeningMemberState(
          memberId: 'member-2',
          displayName: 'Bob',
          deviceLabel: 'Phone',
          role: GroupListeningMemberRole.member,
          presenceState: GroupListeningMemberPresenceState.active,
          joinedAt: joinedAt.add(const Duration(seconds: 2)),
          lastSeenAt: joinedAt.add(const Duration(seconds: 2)),
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
            addedAt: joinedAt,
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
        position: const Duration(seconds: 42),
        capturedAt: joinedAt,
        playbackRate: 1,
        reason: GroupListeningPlaybackAnchorReason.snapshot,
        issuedByMemberId: 'member-1',
      ),
    ),
    lastAppliedRoomVersion: 1,
    snapshotRequired: snapshotRequired,
    failure: failure,
  );
}
