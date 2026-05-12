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
    showDragHandle: false,
    enableDrag: true,
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
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          GestureDetector(
            key: const ValueKey('groupListeningSheetHeader'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragEnd: (details) {
              if (details.primaryVelocity != null &&
                  details.primaryVelocity! > 250) {
                Navigator.of(context).maybePop();
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Column(
                children: <Widget>[
                  Container(
                    key: const ValueKey('groupListeningSheetDragHandle'),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
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
                ],
              ),
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
  static final RegExp _inviteCodePattern = RegExp(r'^[A-Za-z0-9_-]{24}$');
  static final RegExp _pinPattern = RegExp(r'^\d{4}$');

  final _roomPinController = TextEditingController();
  bool _shotgunModeEnabled = false;
  bool _hostOnlyEnabled = false;
  bool _pinProtectedEnabled = false;

  @override
  void dispose() {
    _roomPinController.dispose();
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
    final roomOptions = _selectedRoomOptions();
    if (_pinProtectedEnabled &&
        !_pinPattern.hasMatch(roomOptions.pinCode ?? '')) {
      showAppNotice(
        context,
        message: 'Enter a 4-digit room PIN.',
        level: AppNoticeLevel.error,
      );
      return;
    }
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .createRoom(client: clientDescriptor, roomOptions: roomOptions);
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
  }

  GroupListeningRoomOptions _selectedRoomOptions() {
    return GroupListeningRoomOptions(
      roomMode: _hostOnlyEnabled
          ? GroupListeningRoomMode.hostOnly
          : _shotgunModeEnabled
          ? GroupListeningRoomMode.shotgun
          : GroupListeningRoomMode.collaborative,
      pinCode: _pinProtectedEnabled ? _roomPinController.text.trim() : null,
    );
  }

  Future<GroupListeningErrorState?> _joinRoom(
    GroupListeningClientDescriptor clientDescriptor, {
    required String inviteCode,
    String? pinCode,
  }) async {
    if (inviteCode.isEmpty) {
      showAppNotice(
        context,
        message: 'Enter an invite code to join a room.',
      );
      return const GroupListeningErrorState(
        code: GroupListeningErrorCode.validationFailed,
        message: 'Enter an invite code to join a room.',
      );
    }
    FocusScope.of(context).unfocus();
    final result = await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .joinRoom(
          inviteCode: inviteCode,
          client: clientDescriptor,
          pinCode: pinCode,
        );
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
    return result.failure;
  }

  Future<String?> _clipboardInviteCode() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text?.trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    for (final token in text.split(RegExp('[\\s"\'<>]+'))) {
      final trimmed = token.trim();
      if (_inviteCodePattern.hasMatch(trimmed)) {
        return trimmed;
      }
    }
    return null;
  }

  Future<void> _showJoinWithCodeDialog(
    GroupListeningClientDescriptor clientDescriptor,
  ) async {
    FocusScope.of(context).unfocus();
    final clipboardInviteCode = await _clipboardInviteCode();
    if (!mounted) {
      return;
    }
    String? inviteCode = clipboardInviteCode;
    String? pinCode;
    GroupListeningErrorState? pinFailure;

    while (mounted) {
      final dialogResult =
          await showDialog<({String inviteCode, String? pinCode})>(
            context: context,
            builder: (context) => _JoinWithCodeDialog(
              initialInviteCode: inviteCode,
              pinFailure: pinFailure,
              showClipboardHint: clipboardInviteCode != null,
            ),
          );

      if (!mounted || dialogResult == null) {
        return;
      }
      inviteCode = dialogResult.inviteCode;
      pinCode = dialogResult.pinCode;
      pinFailure = await _joinRoom(
        clientDescriptor,
        inviteCode: inviteCode,
        pinCode: pinCode,
      );
      if (pinFailure?.code != GroupListeningErrorCode.pinRequired &&
          pinFailure?.code != GroupListeningErrorCode.pinInvalid) {
        return;
      }
    }
  }

  Future<GroupListeningErrorState?> _joinAvailableRoom(
    GroupListeningAvailableRoomSummary room,
    GroupListeningClientDescriptor clientDescriptor, {
    String? pinCode,
  }) async {
    FocusScope.of(context).unfocus();
    final result = await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .joinAvailableRoom(
          roomId: room.roomId,
          client: clientDescriptor,
          pinCode: pinCode,
        );
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
    return result.failure;
  }

  Future<void> _joinAvailableRoomWithPinPrompt(
    GroupListeningAvailableRoomSummary room,
    GroupListeningClientDescriptor clientDescriptor,
  ) async {
    String? pinCode;
    if (room.requiresPin) {
      pinCode = await _showRoomPinDialog();
      if (!mounted || pinCode == null) {
        return;
      }
    }
    final failure = await _joinAvailableRoom(
      room,
      clientDescriptor,
      pinCode: pinCode,
    );
    if (!mounted ||
        (failure?.code != GroupListeningErrorCode.pinRequired &&
            failure?.code != GroupListeningErrorCode.pinInvalid)) {
      return;
    }
    final retryPin = await _showRoomPinDialog(failure: failure);
    if (!mounted || retryPin == null) {
      return;
    }
    await _joinAvailableRoom(room, clientDescriptor, pinCode: retryPin);
  }

  Future<String?> _showRoomPinDialog({GroupListeningErrorState? failure}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        String? errorText = switch (failure?.code) {
          GroupListeningErrorCode.pinInvalid => 'That PIN did not work.',
          _ => null,
        };
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              final pin = controller.text.trim();
              if (!_pinPattern.hasMatch(pin)) {
                setDialogState(() {
                  errorText = 'Enter 4 digits.';
                });
                return;
              }
              Navigator.of(context).pop(pin);
            }

            return AlertDialog(
              icon: const Icon(Icons.lock_outline),
              title: const Text('Room PIN'),
              content: TextField(
                key: const ValueKey('groupListeningAvailableRoomPinField'),
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                obscureText: true,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                decoration: InputDecoration(
                  labelText: 'Room PIN',
                  hintText: '4 digits',
                  errorText: errorText,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock_outline),
                ),
                onChanged: (_) {
                  if (errorText != null) {
                    setDialogState(() {
                      errorText = null;
                    });
                  }
                },
                onSubmitted: (_) => submit(),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  key: const ValueKey(
                    'groupListeningAvailableRoomPinConfirmButton',
                  ),
                  onPressed: submit,
                  icon: const Icon(Icons.login_outlined),
                  label: const Text('Join room'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _leaveRoom() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .leaveRoom();
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
  }

  Future<void> _closeRoom() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .closeRoom();
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
  }

  Future<void> _rotateInvite() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .rotateInvite();
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
    showAppNotice(
      context,
      message: 'Invite code copied.',
      level: AppNoticeLevel.success,
    );
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

  String _roomModeLabel(GroupListeningRoomMode roomMode) {
    return switch (roomMode) {
      GroupListeningRoomMode.collaborative => 'Collaborative',
      GroupListeningRoomMode.shotgun => 'Shotgun',
      GroupListeningRoomMode.hostOnly => 'Host only',
    };
  }

  String _controlLabel(GroupListeningSessionState sessionState) {
    final self = sessionState.room?.self;
    if (self == null) {
      return 'Room controls unavailable';
    }
    if (!self.canPlayAudio) {
      return 'Host audio only';
    }
    if (self.canControl) {
      return 'Shared playback enabled';
    }
    return 'Playback locked to room host';
  }

  String _roomPolicyDescription(GroupListeningRoomState room) {
    return switch (room.roomMode) {
      GroupListeningRoomMode.collaborative =>
        'Everyone can control playback and play audio.',
      GroupListeningRoomMode.shotgun =>
        room.self.canPlayAudio
            ? 'Everyone can control playback. Audio plays on this host device.'
            : 'Everyone can control playback. Audio plays on the host device.',
      GroupListeningRoomMode.hostOnly =>
        room.self.canControl
            ? 'Only the host can change playback. Listeners can follow audio.'
            : 'Only the host can change playback. This device follows audio.',
    };
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
      case GroupListeningErrorCode.pinRequired:
        return 'Enter the room PIN to join.';
      case GroupListeningErrorCode.pinInvalid:
        return 'That room PIN did not work.';
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
      case GroupListeningErrorCode.payloadTooLarge:
        return 'Voyage rejected that request because it was too large.';
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
              _MetadataRow(label: 'Mode', value: _roomModeLabel(room.roomMode)),
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
                  if (room?.self.canManageRoom ?? false) ...<Widget>[
                    TextButton.icon(
                      key: const ValueKey('groupListeningCloseRoomButton'),
                      onPressed: _isBusy(sessionState) ? null : _closeRoom,
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Close room'),
                    ),
                    const SizedBox(width: 8),
                  ],
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
            if (!sessionState.hasActiveRoom) ...<Widget>[
              const SizedBox(height: 16),
              _buildRoomSettingsSection(sessionState),
            ],
            const SizedBox(height: 16),
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
                  ? _roomPolicyDescription(sessionState.room!)
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
    if (inviteCode == null || room == null || !room.self.canManageRoom) {
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
                IconButton(
                  key: const ValueKey('groupListeningRotateInviteButton'),
                  tooltip: 'Rotate invite code',
                  onPressed: _isBusy(sessionState) ? null : _rotateInvite,
                  icon: const Icon(Icons.autorenew_outlined),
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
                TextButton.icon(
                  key: const ValueKey('groupListeningJoinWithCodeButton'),
                  onPressed: canJoin
                      ? () => _showJoinWithCodeDialog(clientDescriptor)
                      : null,
                  icon: const Icon(Icons.pin_outlined),
                  label: const Text('Join'),
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
                          leading: Icon(
                            room.requiresPin
                                ? Icons.lock_outline
                                : Icons.meeting_room_outlined,
                          ),
                          title: Text(room.hostDisplayName),
                          subtitle: Text(
                            '${_roomModeLabel(room.roomMode)} - '
                            '${room.activeMembers}/${room.membersTotal} active listeners - '
                            '${room.queueLength} queued tracks - '
                            'updated ${_formatTimestamp(room.lastActivityAt)}',
                          ),
                          trailing: FilledButton.tonalIcon(
                            onPressed: canJoin
                                ? () => _joinAvailableRoomWithPinPrompt(
                                    room,
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

  Widget _buildRoomSettingsSection(GroupListeningSessionState sessionState) {
    final canEdit =
        !sessionState.hasActiveRoom &&
        sessionState.availability == GroupListeningAvailability.ready &&
        !_isBusy(sessionState);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Room settings',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        // Shotgun Mode and Host Only are experimental and hidden for now.
        // State vars are kept so the toggles can be re-enabled when ready.
        _RoomSettingsToggle(
          key: const ValueKey('groupListeningPinProtectedModeToggle'),
          icon: Icons.lock_outline,
          title: 'PIN Protected',
          subtitle: 'Require a 4-digit code to join.',
          value: _pinProtectedEnabled,
          enabled: canEdit,
          onChanged: (value) {
            setState(() {
              _pinProtectedEnabled = value;
              if (!value) {
                _roomPinController.clear();
              }
            });
          },
        ),
        if (_pinProtectedEnabled) ...<Widget>[
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('groupListeningRoomPinField'),
            controller: _roomPinController,
            enabled: canEdit,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: const InputDecoration(
              labelText: 'Room PIN',
              hintText: '4 digits',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.password_outlined),
            ),
          ),
        ],
      ],
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

    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomPadding),
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

class _JoinWithCodeDialog extends StatefulWidget {
  const _JoinWithCodeDialog({
    required this.initialInviteCode,
    required this.pinFailure,
    required this.showClipboardHint,
  });

  final String? initialInviteCode;
  final GroupListeningErrorState? pinFailure;
  final bool showClipboardHint;

  @override
  State<_JoinWithCodeDialog> createState() => _JoinWithCodeDialogState();
}

class _JoinWithCodeDialogState extends State<_JoinWithCodeDialog> {
  static final RegExp _pinPattern = RegExp(r'^\d{4}$');

  late final TextEditingController _inviteController;
  late final TextEditingController _pinController;
  String? _inviteErrorText;
  String? _pinErrorText;

  @override
  void initState() {
    super.initState();
    _inviteController = TextEditingController(text: widget.initialInviteCode);
    _pinController = TextEditingController();
    _pinErrorText = switch (widget.pinFailure?.code) {
      GroupListeningErrorCode.pinRequired => 'Enter this room PIN.',
      GroupListeningErrorCode.pinInvalid => 'That PIN did not work.',
      _ => null,
    };
  }

  @override
  void dispose() {
    _inviteController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  void _submit() {
    final normalized = _inviteController.text.trim();
    if (normalized.isEmpty) {
      setState(() {
        _inviteErrorText = 'Enter an invite code to join a room.';
      });
      return;
    }

    final normalizedPin = _pinController.text.trim();
    if (normalizedPin.isNotEmpty && !_pinPattern.hasMatch(normalizedPin)) {
      setState(() {
        _pinErrorText = 'Enter 4 digits.';
      });
      return;
    }

    Navigator.of(context).pop(
      (
        inviteCode: normalized,
        pinCode: normalizedPin.isEmpty ? null : normalizedPin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.pin_outlined),
      title: const Text('Code Join'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: const ValueKey('groupListeningJoinWithCodeField'),
            controller: _inviteController,
            autofocus: widget.pinFailure == null,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: TextInputType.text,
            decoration: InputDecoration(
              labelText: 'Invite code',
              hintText: 'Paste a Voyage invite',
              errorText: _inviteErrorText,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.meeting_room_outlined),
            ),
            onChanged: (_) {
              if (_inviteErrorText != null) {
                setState(() {
                  _inviteErrorText = null;
                });
              }
            },
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('groupListeningJoinWithCodePinField'),
            controller: _pinController,
            autofocus: widget.pinFailure != null,
            keyboardType: TextInputType.number,
            obscureText: true,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: InputDecoration(
              labelText: 'Room PIN',
              hintText: '4 digits',
              errorText: _pinErrorText,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock_outline),
            ),
            onChanged: (_) {
              if (_pinErrorText != null) {
                setState(() {
                  _pinErrorText = null;
                });
              }
            },
            onSubmitted: (_) => _submit(),
          ),
          if (widget.showClipboardHint) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'Detected an invite code from your clipboard.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey('groupListeningJoinWithCodeCancelButton'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const ValueKey('groupListeningJoinWithCodeConfirmButton'),
          onPressed: _submit,
          icon: const Icon(Icons.login_outlined),
          label: const Text('Join room'),
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

class _RoomSettingsToggle extends StatelessWidget {
  const _RoomSettingsToggle({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
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
