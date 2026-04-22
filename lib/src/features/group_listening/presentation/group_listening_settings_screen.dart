import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class GroupListeningSettingsScreen extends ConsumerStatefulWidget {
  const GroupListeningSettingsScreen({super.key});

  @override
  ConsumerState<GroupListeningSettingsScreen> createState() =>
      _GroupListeningSettingsScreenState();
}

class _GroupListeningSettingsScreenState
    extends ConsumerState<GroupListeningSettingsScreen> {
  final _inviteCodeController = TextEditingController();
  final _voyageServerUrlController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _deviceLabelController = TextEditingController();

  bool _enabled = false;
  bool _autoFollowHost = true;
  bool _initialized = false;

  @override
  void dispose() {
    _inviteCodeController.dispose();
    _voyageServerUrlController.dispose();
    _displayNameController.dispose();
    _deviceLabelController.dispose();
    super.dispose();
  }

  void _initFromSettings(AppSettingsModel settings) {
    if (_initialized) return;
    _initialized = true;
    _enabled = settings.groupListeningEnabled;
    _autoFollowHost = settings.voyageAutoFollowHost;
    _voyageServerUrlController.text = settings.voyageServerUrl ?? '';
    _displayNameController.text = settings.voyageDisplayName ?? '';
    _deviceLabelController.text = settings.voyageDeviceLabel ?? '';
  }

  Future<void> _save() async {
    final repository = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    final voyageServerUrl = _voyageServerUrlController.text.trim();
    final displayName = _displayNameController.text.trim();
    final deviceLabel = _deviceLabelController.text.trim();

    await repository.saveSettings(
      current.copyWith(
        groupListeningEnabled: _enabled,
        voyageServerUrl: voyageServerUrl.isEmpty ? null : voyageServerUrl,
        voyageDisplayName: displayName.isEmpty ? null : displayName,
        voyageDeviceLabel: deviceLabel.isEmpty ? null : deviceLabel,
        voyageAutoFollowHost: _autoFollowHost,
        clearVoyageServerUrl: voyageServerUrl.isEmpty,
        clearVoyageDisplayName: displayName.isEmpty,
        clearVoyageDeviceLabel: deviceLabel.isEmpty,
      ),
    );
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
  }

  Future<void> _joinRoom(
    GroupListeningClientDescriptor clientDescriptor,
  ) async {
    final inviteCode = _inviteCodeController.text.trim();
    if (inviteCode.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an invite code to join a room.')),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .joinRoom(inviteCode: inviteCode, client: clientDescriptor);
  }

  Future<void> _leaveRoom() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .leaveRoom();
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

  String _availabilityMessage(GroupListeningSessionState sessionState) {
    switch (sessionState.availability) {
      case GroupListeningAvailability.disabled:
        return 'Turn on group listening to create or join rooms.';
      case GroupListeningAvailability.unconfigured:
        return 'Finish the Voyage URL and make sure Navis is signed in before joining a room.';
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
        return 'Group listening is off';
      case GroupListeningAvailability.unconfigured:
        return 'Finish setup';
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
        return 'Complete the Voyage server URL and sign in before starting a room.';
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
              'Create, join, or recover a room without storing any Voyage tokens in app settings.',
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
                  _joinRoom(clientDescriptor);
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
                if (sessionState.hasActiveRoom)
                  TextButton.icon(
                    key: const ValueKey('groupListeningLeaveRoomButton'),
                    onPressed: _leaveRoom,
                    icon: const Icon(Icons.logout_outlined),
                    label: const Text('Leave room'),
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
                  ? 'Playback handoff is wired separately, so this screen stays focused on room lifecycle, roles, and sync health.'
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

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final sessionState = ref.watch(groupListeningSessionControllerProvider);
    final clientDescriptor = ref.watch(groupListeningClientDescriptorProvider);

    ref.listen<GroupListeningErrorState?>(
      groupListeningSessionControllerProvider.select((state) => state.failure),
      (previous, next) {
        if (next == null || next == previous || !mounted) {
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_failureDescription(next))));
      },
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Group Listening')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (settings) {
          _initFromSettings(settings);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              _buildOverviewCard(sessionState),
              const SizedBox(height: 12),
              _buildActionsCard(sessionState, clientDescriptor),
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: <Widget>[
                    SwitchListTile(
                      key: const ValueKey('groupListeningEnabledSwitch'),
                      secondary: const Icon(Icons.headset_mic_outlined),
                      title: const Text('Enable group listening'),
                      subtitle: const Text(
                        'Allow Navis to use locally stored Voyage connection preferences.',
                      ),
                      value: _enabled,
                      onChanged: (value) {
                        setState(() => _enabled = value);
                        _save();
                      },
                    ),
                    SwitchListTile(
                      key: const ValueKey('groupListeningAutoFollowHostSwitch'),
                      secondary: const Icon(Icons.sync_alt_outlined),
                      title: const Text('Auto-follow host playback'),
                      subtitle: const Text(
                        'Prefer host-led play, pause, and seek updates when joining a room.',
                      ),
                      value: _autoFollowHost,
                      onChanged: (value) {
                        setState(() => _autoFollowHost = value);
                        _save();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Voyage connection',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey(
                          'groupListeningVoyageServerUrlField',
                        ),
                        controller: _voyageServerUrlController,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Voyage server URL',
                          hintText: 'https://voyage.example.com',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.link),
                        ),
                        onChanged: (_) => _save(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('groupListeningDisplayNameField'),
                        controller: _displayNameController,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                          hintText: 'Shown to other listeners',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        onChanged: (_) => _save(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('groupListeningDeviceLabelField'),
                        controller: _deviceLabelController,
                        decoration: const InputDecoration(
                          labelText: 'Device label',
                          hintText: 'Optional device nickname',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.devices_outlined),
                        ),
                        onChanged: (_) => _save(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text(
                    'Sensitive Voyage tokens are not stored here',
                  ),
                  subtitle: const Text(
                    'Only non-sensitive configuration is stored in app settings. Room tokens and secrets must stay in secure storage.',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.tune_outlined),
                  title: const Text(
                    'Playback bridge is being wired separately',
                  ),
                  subtitle: const Text(
                    'This MVP screen focuses on room setup, membership, and sync visibility so it does not overlap with the active playback-bridge work.',
                  ),
                ),
              ),
            ],
          );
        },
      ),
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
