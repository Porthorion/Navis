import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_sync_bridge.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';

Future<void> showListenTogetherSheet(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  final heightFactor = mediaQuery.size.width >= 840 ? 0.88 : 0.94;
  // Capture the notice controller from the caller's context so the modal can
  // surface top-pill notifications even when pushed onto the root Navigator
  // (which sits above AppNoticeScope in the widget tree).
  final noticeController = AppNoticeScope.maybeOf(context);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      Widget surface = FractionallySizedBox(
        heightFactor: heightFactor,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: const _ListenTogetherSurface(showAppBar: false),
          ),
        ),
      );
      if (noticeController != null) {
        surface = AppNoticeScope(notifier: noticeController, child: surface);
      }
      return surface;
    },
  );
}

class GroupListeningSettingsScreen extends StatelessWidget {
  const GroupListeningSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _ListenTogetherSurface(showAppBar: true);
  }
}

class _ListenTogetherSurface extends StatelessWidget {
  const _ListenTogetherSurface({required this.showAppBar});

  final bool showAppBar;

  @override
  Widget build(BuildContext context) {
    const body = _ListenTogetherRoomContent();
    if (showAppBar) {
      return Scaffold(
        appBar: AppBar(title: const Text('Listen Together')),
        body: body,
      );
    }

    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: <Widget>[
                Text(
                  'Listen Together',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Close Listen Together',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _ListenTogetherRoomContent extends ConsumerStatefulWidget {
  const _ListenTogetherRoomContent();

  @override
  ConsumerState<_ListenTogetherRoomContent> createState() =>
      _ListenTogetherRoomContentState();
}

class _ListenTogetherRoomContentState
    extends ConsumerState<_ListenTogetherRoomContent> {
  final _inviteCodeController = TextEditingController();

  @override
  void dispose() {
    _inviteCodeController.dispose();
    super.dispose();
  }

  bool _isBusy(GroupListeningSessionState sessionState) {
    switch (sessionState.status) {
      case GroupListeningSessionStatus.joining:
      case GroupListeningSessionStatus.connecting:
      case GroupListeningSessionStatus.reconnecting:
      case GroupListeningSessionStatus.disconnecting:
      case GroupListeningSessionStatus.leaving:
        return true;
      case GroupListeningSessionStatus.idle:
      case GroupListeningSessionStatus.connected:
      case GroupListeningSessionStatus.error:
        return false;
    }
  }

  Future<void> _createRoom(
    GroupListeningClientDescriptor clientDescriptor,
  ) async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .createRoom(client: clientDescriptor);
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
  }

  Future<void> _joinRoom(
    GroupListeningClientDescriptor clientDescriptor,
  ) async {
    final inviteCode = _inviteCodeController.text.trim();
    if (inviteCode.isEmpty) {
      showAppNotice(
        context,
        message: 'Enter an invite code to join a room.',
      );
      return;
    }
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .joinRoom(inviteCode: inviteCode, client: clientDescriptor);
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
  }

  Future<void> _joinAvailableRoom(
    String roomId,
    GroupListeningClientDescriptor clientDescriptor,
  ) async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .joinAvailableRoom(roomId: roomId, client: clientDescriptor);
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
  }

  Future<void> _leaveRoom() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .leaveRoom();
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
  }

  Future<void> _connectTransport() async {
    FocusScope.of(context).unfocus();
    await ref.read(groupListeningSessionControllerProvider.notifier).connect();
  }

  Future<void> _reconnect() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .reconnect();
  }

  Future<void> _refreshSnapshot() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .refreshSnapshot();
  }

  void _dismissFailure() {
    ref.read(groupListeningSessionControllerProvider.notifier).clearFailure();
  }

  Future<void> _copyInviteCode(String inviteCode) async {
    await Clipboard.setData(ClipboardData(text: inviteCode));
    if (!mounted) {
      return;
    }
    showAppNotice(context, message: 'Invite code copied.', level: AppNoticeLevel.success);
  }

  String _availabilityMessage(GroupListeningSessionState sessionState) {
    switch (sessionState.availability) {
      case GroupListeningAvailability.disabled:
        return 'Turn on Listen Together in configuration before creating or joining rooms.';
      case GroupListeningAvailability.unconfigured:
        return 'Finish the Voyage connection setup and make sure Navis is signed in before joining a room.';
      case GroupListeningAvailability.ready:
        return sessionState.hasActiveRoom
            ? 'Room setup is ready. Use the controls below to reconnect, refresh, or leave.'
            : 'Create a room to host listeners or join with an invite code.';
    }
  }

  String _sessionTitle(GroupListeningSessionState sessionState) {
    if (sessionState.hasActiveRoom) {
      return 'Active room';
    }
    switch (sessionState.availability) {
      case GroupListeningAvailability.disabled:
        return 'Listen Together is off';
      case GroupListeningAvailability.unconfigured:
        return 'Finish configuration';
      case GroupListeningAvailability.ready:
        return 'No active room';
    }
  }

  String _connectionLabel(GroupListeningSessionState sessionState) {
    switch (sessionState.connection.status) {
      case GroupListeningConnectionStatus.connected:
        return 'Connected';
      case GroupListeningConnectionStatus.connecting:
        return 'Connecting';
      case GroupListeningConnectionStatus.reconnecting:
        return 'Reconnecting';
      case GroupListeningConnectionStatus.disconnected:
        return sessionState.hasActiveRoom ? 'Disconnected' : 'Offline';
    }
  }

  String _syncLabel(GroupListeningSessionState sessionState) {
    if (sessionState.snapshotRequired) {
      return 'Snapshot required';
    }
    if (!sessionState.hasActiveRoom) {
      return 'No room joined';
    }
    if (sessionState.connection.isConnected) {
      return 'In sync';
    }
    return 'Waiting for transport';
  }

  String _controlLabel(GroupListeningSessionState sessionState) {
    final self = sessionState.room?.self;
    if (self == null) {
      return 'Room controls unavailable';
    }
    if (self.canControl) {
      return 'Playback control enabled';
    }
    return 'Following the host playback';
  }

  String _failureDescription(GroupListeningErrorState failure) {
    switch (failure.code) {
      case GroupListeningErrorCode.transportUnavailable:
        return 'Navis could not reach the Voyage server or open its realtime transport.';
      case GroupListeningErrorCode.snapshotRequired:
        return 'Navis needs a fresh room snapshot before it can trust the shared state again.';
      case GroupListeningErrorCode.configurationMissing:
        return 'Complete the Voyage configuration and sign in before starting a room.';
      case GroupListeningErrorCode.fingerprintMismatch:
        return 'This room belongs to a different server profile. Rejoin it from the matching Subsonic account.';
      case GroupListeningErrorCode.inviteInvalid:
      case GroupListeningErrorCode.inviteExpired:
        return 'That invite code is no longer valid. Ask the host for a fresh one.';
      case GroupListeningErrorCode.roomClosed:
        return 'This room is closed.';
      case GroupListeningErrorCode.roomNotFound:
        return 'Navis could not find that room.';
      case GroupListeningErrorCode.unauthorized:
      case GroupListeningErrorCode.forbidden:
        return 'Navis was not allowed to complete that room action.';
      case GroupListeningErrorCode.sessionUnavailable:
        return 'There is no stored room session to reconnect right now.';
      case GroupListeningErrorCode.transportDisconnected:
        return 'The realtime room transport disconnected.';
      case GroupListeningErrorCode.insecureTransport:
        return 'Use HTTPS for remote Voyage servers. HTTP is only allowed for local development endpoints.';
      case GroupListeningErrorCode.removed:
      case GroupListeningErrorCode.revoked:
        return 'You no longer have access to this room.';
      case GroupListeningErrorCode.rateLimited:
        return 'Too many room requests were sent at once. Try again in a moment.';
      case GroupListeningErrorCode.validationFailed:
        return 'Voyage rejected that room request. Double-check the invite code and room settings.';
      case GroupListeningErrorCode.unsupportedProtocolVersion:
      case GroupListeningErrorCode.staleVersion:
      case GroupListeningErrorCode.sequenceRejected:
      case GroupListeningErrorCode.duplicateMutation:
      case GroupListeningErrorCode.internalError:
      case GroupListeningErrorCode.unknown:
        return failure.message;
    }
  }

  String? _hostDisplayName(GroupListeningSessionState sessionState) {
    final room = sessionState.room;
    if (room == null) {
      return null;
    }
    for (final member in room.members) {
      if (member.memberId == room.hostMemberId) {
        return member.displayName;
      }
    }
    return null;
  }

  String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    final hours = local.hour.toString().padLeft(2, '0');
    final minutes = local.minute.toString().padLeft(2, '0');
    final seconds = local.second.toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  Widget _buildOverviewCard(GroupListeningSessionState sessionState) {
    final room = sessionState.room;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  room == null
                      ? Icons.headset_mic_outlined
                      : room.self.role == GroupListeningMemberRole.host
                      ? Icons.record_voice_over_outlined
                      : Icons.people_alt_outlined,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _sessionTitle(sessionState),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _availabilityMessage(sessionState),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (room != null) ...<Widget>[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _StatusChip(
                    icon: room.self.role == GroupListeningMemberRole.host
                        ? Icons.shield_outlined
                        : Icons.person_outline,
                    label: room.self.role == GroupListeningMemberRole.host
                        ? 'Host'
                        : 'Listener',
                  ),
                  _StatusChip(
                    icon: sessionState.connection.isConnected
                        ? Icons.wifi_tethering_outlined
                        : Icons.wifi_off_outlined,
                    label: _connectionLabel(sessionState),
                  ),
                  _StatusChip(
                    icon: sessionState.snapshotRequired
                        ? Icons.sync_problem_outlined
                        : Icons.sync_outlined,
                    label: _syncLabel(sessionState),
                  ),
                  _StatusChip(
                    icon: room.self.canControl
                        ? Icons.play_circle_outline
                        : Icons.hearing_outlined,
                    label: _controlLabel(sessionState),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _MetadataRow(label: 'Room', value: room.roomId),
              _MetadataRow(label: 'Listeners', value: '${room.members.length}'),
              _MetadataRow(
                label: 'Queued tracks',
                value: '${room.queue.entries.length}',
              ),
              if (_hostDisplayName(sessionState) != null)
                _MetadataRow(
                  label: 'Host',
                  value: _hostDisplayName(sessionState)!,
                ),
              if (sessionState.lastSnapshotAt != null)
                _MetadataRow(
                  label: 'Last snapshot',
                  value: _formatTimestamp(sessionState.lastSnapshotAt!),
                ),
            ],
            if (sessionState.failure != null) ...<Widget>[
              const SizedBox(height: 16),
              _FailureCard(
                failure: sessionState.failure!,
                message: _failureDescription(sessionState.failure!),
                onDismiss: _dismissFailure,
              ),
            ],
            if (sessionState.hasActiveRoom) ...<Widget>[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton.icon(
                    key: const ValueKey('groupListeningLeaveRoomButton'),
                    onPressed: _isBusy(sessionState) ? null : _leaveRoom,
                    icon: const Icon(Icons.logout_outlined),
                    label: const Text('Leave room'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionsCard(
    GroupListeningSessionState sessionState,
    GroupListeningClientDescriptor clientDescriptor,
  ) {
    final isBusy = _isBusy(sessionState);
    final canStartRoom =
        sessionState.availability == GroupListeningAvailability.ready &&
        !isBusy &&
        !sessionState.hasActiveRoom;
    final canJoinRoom =
        canStartRoom && _inviteCodeController.text.trim().isNotEmpty;
    final canRecoverActiveRoom = sessionState.hasActiveRoom && !isBusy;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Room controls',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Create a room, join with an invite, or pick an available room on this server.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('groupListeningInviteCodeField'),
              controller: _inviteCodeController,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Invite code',
                hintText: 'Paste a Voyage invite',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.meeting_room_outlined),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (canJoinRoom) {
                  unawaited(_joinRoom(clientDescriptor));
                }
              },
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                FilledButton.icon(
                  key: const ValueKey('groupListeningCreateRoomButton'),
                  onPressed: canStartRoom
                      ? () => _createRoom(clientDescriptor)
                      : null,
                  icon: const Icon(Icons.add_home_outlined),
                  label: const Text('Create room'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('groupListeningJoinRoomButton'),
                  onPressed: canJoinRoom
                      ? () => _joinRoom(clientDescriptor)
                      : null,
                  icon: const Icon(Icons.login_outlined),
                  label: const Text('Join room'),
                ),
                if (canRecoverActiveRoom &&
                    sessionState.connection.status ==
                        GroupListeningConnectionStatus.disconnected &&
                    !sessionState.snapshotRequired)
                  TextButton.icon(
                    key: const ValueKey('groupListeningConnectTransportButton'),
                    onPressed: _connectTransport,
                    icon: const Icon(Icons.wifi_tethering_outlined),
                    label: const Text('Connect transport'),
                  ),
                if (canRecoverActiveRoom &&
                    sessionState.failure != null &&
                    sessionState.connection.status !=
                        GroupListeningConnectionStatus.connected)
                  TextButton.icon(
                    key: const ValueKey('groupListeningReconnectButton'),
                    onPressed: _reconnect,
                    icon: const Icon(Icons.refresh_outlined),
                    label: const Text('Reconnect room'),
                  ),
                if (canRecoverActiveRoom && sessionState.snapshotRequired)
                  TextButton.icon(
                    key: const ValueKey('groupListeningRefreshSnapshotButton'),
                    onPressed: _refreshSnapshot,
                    icon: const Icon(Icons.sync_outlined),
                    label: const Text('Refresh snapshot'),
                  ),
              ],
            ),
            if (isBusy) ...<Widget>[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 12),
            Text(
              sessionState.hasActiveRoom
                  ? 'Shared queue updates stay collaborative, so add, remove, and reorder actions stay aligned for everyone in the room.'
                  : _availabilityMessage(sessionState),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInviteCard(GroupListeningSessionState sessionState) {
    final inviteCode = sessionState.activeInviteCode;
    final room = sessionState.room;
    if (inviteCode == null ||
        room == null ||
        room.self.role != GroupListeningMemberRole.host) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.ios_share_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Invite listeners',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy invite code',
                  onPressed: () => _copyInviteCode(inviteCode),
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              inviteCode,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvailableRoomsCard(
    GroupListeningSessionState sessionState,
    GroupListeningClientDescriptor clientDescriptor,
    AsyncValue<List<GroupListeningAvailableRoomSummary>> roomsAsync,
  ) {
    final isBusy = _isBusy(sessionState);
    final canJoin =
        sessionState.availability == GroupListeningAvailability.ready &&
        !isBusy &&
        !sessionState.hasActiveRoom;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.groups_2_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Available rooms',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh available rooms',
                  onPressed: () =>
                      ref.invalidate(groupListeningAvailableRoomsProvider),
                  icon: const Icon(Icons.refresh_outlined),
                ),
              ],
            ),
            const SizedBox(height: 8),
            roomsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _failureDescription(
                    error is GroupListeningRepositoryException
                        ? error.failure
                        : const GroupListeningErrorState(
                            code: GroupListeningErrorCode.transportUnavailable,
                            message: 'Unable to load available rooms.',
                            retryable: true,
                          ),
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
              data: (rooms) {
                final visibleRooms = rooms
                    .where((room) => room.roomId != sessionState.room?.roomId)
                    .toList(growable: false);
                if (visibleRooms.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      sessionState.availability ==
                              GroupListeningAvailability.ready
                          ? 'No other active rooms are available for this server.'
                          : 'Rooms appear here after Listen Together is ready.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  );
                }
                return Column(
                  children: visibleRooms
                      .map(
                        (room) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.meeting_room_outlined),
                          title: Text(room.hostDisplayName),
                          subtitle: Text(
                            '${room.activeMembers}/${room.membersTotal} active listeners - '
                            '${room.queueLength} queued tracks - '
                            'updated ${_formatTimestamp(room.lastActivityAt)}',
                          ),
                          trailing: FilledButton.tonalIcon(
                            onPressed: canJoin
                                ? () => _joinAvailableRoom(
                                    room.roomId,
                                    clientDescriptor,
                                  )
                                : null,
                            icon: const Icon(Icons.login_outlined),
                            label: const Text('Join'),
                          ),
                        ),
                      )
                      .toList(growable: false),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessionState = ref.watch(groupListeningSessionControllerProvider);
    final clientDescriptor = ref.watch(groupListeningClientDescriptorProvider);
    final availableRooms = ref.watch(groupListeningAvailableRoomsProvider);

    ref.listen<GroupListeningErrorState?>(
      groupListeningSessionControllerProvider.select((state) => state.failure),
      (previous, next) {
        if (next == null || next == previous || !mounted) {
          return;
        }
        showAppNotice(
          context,
          message: _failureDescription(next),
          level: AppNoticeLevel.error,
        );
      },
    );

    ref.listen<int>(
      groupListeningQueueTrackAddedProvider,
      (previous, next) {
        if (previous != null && next > previous && mounted) {
          showAppNotice(
            context,
            message: 'Track added to queue.',
            level: AppNoticeLevel.success,
          );
        }
      },
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (sessionState.activeInviteCode != null) ...<Widget>[
          _buildInviteCard(sessionState),
          const SizedBox(height: 12),
        ],
        // Only show the session status card when it has something meaningful
        // to display: when in a room, when the feature is not fully ready
        // (disabled/unconfigured), or when there is an active failure.
        if (sessionState.hasActiveRoom ||
            sessionState.availability != GroupListeningAvailability.ready ||
            sessionState.failure != null) ...<Widget>[
          _buildOverviewCard(sessionState),
          const SizedBox(height: 12),
        ],
        _buildActionsCard(sessionState, clientDescriptor),
        const SizedBox(height: 12),
        _buildAvailableRoomsCard(
          sessionState,
          clientDescriptor,
          availableRooms,
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(avatar: Icon(icon, size: 18), label: Text(label));
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({
    required this.failure,
    required this.message,
    required this.onDismiss,
  });

  final GroupListeningErrorState failure;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Room issue',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
                if (failure.retryable ||
                    failure.retryAfter != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    failure.retryAfter == null
                        ? 'You can retry this room action now.'
                        : 'Try again in ${failure.retryAfter!.inSeconds}s.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            color: scheme.onErrorContainer,
            icon: const Icon(Icons.close),
            tooltip: 'Dismiss room issue',
          ),
        ],
      ),
    );
  }
}
