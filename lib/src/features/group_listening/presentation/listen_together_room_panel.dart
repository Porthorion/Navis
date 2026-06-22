import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_track_resolution_service.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_track_ref_factory.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_sync_bridge.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/features/group_listening/presentation/listen_together_join_dialogs.dart';
import 'package:navis/src/features/group_listening/presentation/listen_together_settings_widgets.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/song_id_utils.dart';
import 'package:uuid/uuid.dart';

class ListenTogetherRoomPanel extends ConsumerStatefulWidget {
  const ListenTogetherRoomPanel();

  @override
  ConsumerState<ListenTogetherRoomPanel> createState() =>
      ListenTogetherRoomPanelState();
}

class ListenTogetherRoomPanelState
    extends ConsumerState<ListenTogetherRoomPanel> {
  static const Color _activeMemberStatusColor = Color(0xFF2E7D32);
  static const Color _staleMemberStatusColor = Color(0xFFED6C02);
  static const Color _offlineMemberStatusColor = Color(0xFFD32F2F);

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
        !listenTogetherPinPattern.hasMatch(roomOptions.pinCode ?? '')) {
      showAppNotice(
        context,
        message: 'Enter a 4-digit room PIN.',
        level: AppNoticeLevel.error,
      );
      return;
    }
    FocusScope.of(context).unfocus();
    final roomSeed = _buildRoomSeedFromLocalPlayback();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .createRoom(
          client: clientDescriptor,
          roomOptions: roomOptions,
          roomSeed: roomSeed,
        );
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
  }

  GroupListeningRoomSeed? _buildRoomSeedFromLocalPlayback() {
    final playback = ref.read(playerStateProvider);
    if (playback.queueSongIds.isEmpty || playback.isRadioMode) {
      return null;
    }
    final sessionConfig = ref.read(groupListeningClientConfigurationProvider);
    if (sessionConfig == null) {
      return null;
    }
    final now = DateTime.now();
    final entries = <GroupListeningQueueEntry>[];
    for (final songId in playback.queueSongIds) {
      final song = ref.read(songByIdProvider(songId)).asData?.value;
      entries.add(
        GroupListeningQueueEntry(
          queueEntryId: const Uuid().v4(),
          songId: songId,
          addedAt: now,
          title: song?.title,
          artist: song?.artistName,
          artistId: song?.artistId,
          album: song?.albumName,
          albumId: song?.albumId,
          durationSeconds: song?.duration,
          track: song?.track,
          discNumber: song?.discNumber,
          coverArt: song?.coverArt,
          replayGainTrackGain: song?.replayGainTrackGain,
          replayGainAlbumGain: song?.replayGainAlbumGain,
          replayGainTrackPeak: song?.replayGainTrackPeak,
          replayGainAlbumPeak: song?.replayGainAlbumPeak,
          trackRef: _trackRefForSeedSong(songId: songId, song: song),
          playability: playabilityForSongId(songId),
        ),
      );
    }
    final currentIndex = playback.currentIndex ?? 0;
    final currentEntry = currentIndex >= 0 && currentIndex < entries.length
        ? entries[currentIndex]
        : null;
    return GroupListeningRoomSeed(
      queue: GroupListeningQueueState(
        queueVersion: 0,
        currentIndex: currentIndex,
        entries: entries,
      ),
      playbackAnchor: GroupListeningPlaybackAnchor(
        roomVersion: 0,
        queueVersion: 0,
        currentIndex: currentIndex,
        currentQueueEntryId: currentEntry?.queueEntryId,
        currentSongId: currentEntry?.songId,
        playbackState: playback.playing
            ? GroupListeningPlaybackStatus.playing
            : GroupListeningPlaybackStatus.paused,
        position: playback.position,
        capturedAt: now,
        playbackRate:
            ref.read(appSettingsProvider).asData?.value.playbackSpeed ?? 1.0,
        reason: GroupListeningPlaybackAnchorReason.snapshot,
      ),
    );
  }

  GroupListeningTrackRef? _trackRefForSeedSong({
    required String songId,
    required dynamic song,
  }) {
    if (isServerAddressableSongId(songId)) {
      return GroupListeningTrackRef(
        kind: GroupListeningTrackRefKind.libraryId,
        librarySongId: songId,
        source: GroupListeningTrackRefSource.navidrome,
      );
    }
    final title = song?.title?.toString() ?? '';
    final artist = song?.artistName?.toString() ?? '';
    if (title.isEmpty && artist.isEmpty) {
      return null;
    }
    return GroupListeningTrackRef(
      kind: GroupListeningTrackRefKind.searchFingerprint,
      searchFingerprint: GroupListeningSearchFingerprint(
        title: title,
        artist: artist,
        album: song?.albumName?.toString(),
        durationSeconds: song?.duration as int? ?? 0,
      ),
      source: GroupListeningTrackRefSource.search3Remote,
    );
  }

  Future<void> _toggleAutoFollowHost(bool enabled) async {
    final current =
        ref.read(appSettingsProvider).asData?.value ??
        AppSettingsModel.defaults();
    final repository = ref.read(settingsRepositoryProvider);
    await repository.saveSettings(
      current.copyWith(voyageAutoFollowHost: enabled),
    );
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

  Future<String?> readListenTogetherClipboardInviteCode() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text?.trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    for (final token in text.split(RegExp('[\\s"\'<>]+'))) {
      final trimmed = token.trim();
      if (listenTogetherInviteCodePattern.hasMatch(trimmed)) {
        return trimmed;
      }
    }
    return null;
  }

  Future<void> _showJoinWithCodeDialog(
    GroupListeningClientDescriptor clientDescriptor,
  ) async {
    FocusScope.of(context).unfocus();
    final clipboardInviteCode = await readListenTogetherClipboardInviteCode();
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
            builder: (context) => ListenTogetherJoinWithCodeDialog(
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
      pinCode = await showListenTogetherRoomPinDialog(context);
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
    final retryPin = await showListenTogetherRoomPinDialog(
      context,
      failure: failure,
    );
    if (!mounted || retryPin == null) {
      return;
    }
    await _joinAvailableRoom(room, clientDescriptor, pinCode: retryPin);
  }

  Future<void> _leaveRoom() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .leaveRoom(source: 'settings-ui');
    if (mounted) ref.invalidate(groupListeningAvailableRoomsProvider);
  }

  Future<void> _rotateInvite() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .rotateInvite(source: 'settings-ui');
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
        .refreshSnapshot(reason: 'settings-ui');
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

  Future<void> _transferHost(GroupListeningMemberState member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.swap_horiz_outlined),
        title: const Text('Transfer host'),
        content: Text('Make ${member.displayName} the new room host?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Transfer host'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }

    final mutationId = await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .transferHost(targetMemberId: member.memberId, source: 'settings-ui');
    if (!mounted || mutationId == null) {
      return;
    }
    showAppNotice(
      context,
      message: 'Host transfer requested.',
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
      case GroupListeningErrorCode.playbackRewindRejected:
        return 'That playback change would rewind the room and was rejected.';
      case GroupListeningErrorCode.stalePlaybackEpoch:
        return 'Your playback state is behind the room. Catch up before sending playback changes.';
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

  String? _hostDisplayName(GroupListeningSessionState sessionState) =>
      sessionState.room?.hostMember?.displayName;

  String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    final hours = local.hour.toString().padLeft(2, '0');
    final minutes = local.minute.toString().padLeft(2, '0');
    final seconds = local.second.toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String _presenceLabel(GroupListeningMemberPresenceState presenceState) {
    return switch (presenceState) {
      GroupListeningMemberPresenceState.active => 'Connected',
      GroupListeningMemberPresenceState.stale => 'Stale',
      GroupListeningMemberPresenceState.offline => 'Offline',
    };
  }

  IconData _presenceIcon({
    required GroupListeningMemberPresenceState presenceState,
    required bool isHost,
  }) {
    if (isHost) {
      return Icons.workspace_premium_rounded;
    }
    return Icons.circle;
  }

  Color _presenceColor(GroupListeningMemberPresenceState presenceState) {
    return switch (presenceState) {
      GroupListeningMemberPresenceState.active => _activeMemberStatusColor,
      GroupListeningMemberPresenceState.stale => _staleMemberStatusColor,
      GroupListeningMemberPresenceState.offline => _offlineMemberStatusColor,
    };
  }

  String _connectedUsersSummary(GroupListeningRoomState room) {
    final active = room.activeMemberCount;
    final stale = room.staleMemberCount;
    if (stale == 0) {
      return '$active active';
    }
    return '$active active · $stale stale';
  }

  List<GroupListeningMemberState> _sortedRoomMembers(
    GroupListeningRoomState room,
  ) {
    final members = List<GroupListeningMemberState>.of(room.members);
    members.sort((a, b) {
      final aIsHost = a.memberId == room.hostMemberId;
      final bIsHost = b.memberId == room.hostMemberId;
      if (aIsHost != bIsHost) {
        return aIsHost ? -1 : 1;
      }
      if (a.presenceState != b.presenceState) {
        const ranks = <GroupListeningMemberPresenceState, int>{
          GroupListeningMemberPresenceState.active: 0,
          GroupListeningMemberPresenceState.stale: 1,
          GroupListeningMemberPresenceState.offline: 2,
        };
        return ranks[a.presenceState]!.compareTo(ranks[b.presenceState]!);
      }
      return a.joinedAt.compareTo(b.joinedAt);
    });
    return members;
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
                  ListenTogetherStatusChip(
                    icon: room.self.role == GroupListeningMemberRole.host
                        ? Icons.shield_outlined
                        : Icons.person_outline,
                    label: room.self.role == GroupListeningMemberRole.host
                        ? 'Host'
                        : 'Listener',
                  ),
                  ListenTogetherStatusChip(
                    icon: sessionState.connection.isConnected
                        ? Icons.wifi_tethering_outlined
                        : Icons.wifi_off_outlined,
                    label: _connectionLabel(sessionState),
                  ),
                  ListenTogetherStatusChip(
                    icon: sessionState.snapshotRequired
                        ? Icons.sync_problem_outlined
                        : Icons.sync_outlined,
                    label: _syncLabel(sessionState),
                  ),
                  ListenTogetherStatusChip(
                    icon: room.self.canControl
                        ? Icons.play_circle_outline
                        : Icons.hearing_outlined,
                    label: _controlLabel(sessionState),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ListenTogetherMetadataRow(label: 'Room', value: room.roomId),
              ListenTogetherMetadataRow(
                label: 'Mode',
                value: _roomModeLabel(room.roomMode),
              ),
              ListenTogetherMetadataRow(
                label: 'Connected users',
                value: '${room.activeMemberCount}/${room.members.length}',
              ),
              ListenTogetherMetadataRow(
                label: 'Queued tracks',
                value: '${room.queue.entries.length}',
              ),
              if (room.queue.entries.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                ...room.queue.entries.take(8).map((entry) {
                  final resolutionService = ref.watch(
                    groupListeningTrackResolutionServiceProvider,
                  );
                  final readiness = resolutionService.readinessFor(
                    entry.queueEntryId,
                  );
                  return ListenTogetherQueueResolutionTile(
                    entry: entry,
                    readiness: readiness,
                  );
                }),
              ],
              if (_hostDisplayName(sessionState) != null)
                ListenTogetherMetadataRow(
                  label: 'Host',
                  value: _hostDisplayName(sessionState)!,
                ),
              if (sessionState.lastSnapshotAt != null)
                ListenTogetherMetadataRow(
                  label: 'Last snapshot',
                  value: _formatTimestamp(sessionState.lastSnapshotAt!),
                ),
            ],
            if (sessionState.failure != null) ...<Widget>[
              const SizedBox(height: 16),
              ListenTogetherFailureCard(
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

  Widget _buildConnectedUsersCard(GroupListeningSessionState sessionState) {
    final room = sessionState.room;
    if (room == null) {
      return const SizedBox.shrink();
    }

    final members = _sortedRoomMembers(room);
    final theme = Theme.of(context);
    final canTransferHost = room.self.canManageRoom && !_isBusy(sessionState);

    return Card(
      key: const ValueKey('groupListeningConnectedUsersCard'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.groups_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Connected users',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _connectedUsersSummary(room),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final entry in members.asMap().entries) ...<Widget>[
              if (entry.key > 0) const Divider(height: 16),
              ListTile(
                key: ValueKey(
                  'groupListeningMemberTile-${entry.value.memberId}',
                ),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  key: ValueKey(
                    'groupListeningMemberIcon-${entry.value.memberId}',
                  ),
                  _presenceIcon(
                    presenceState: entry.value.presenceState,
                    isHost: entry.value.memberId == room.hostMemberId,
                  ),
                  color: _presenceColor(entry.value.presenceState),
                ),
                title: Row(
                  children: <Widget>[
                    Expanded(child: Text(entry.value.displayName)),
                    if (entry.value.memberId == room.self.memberId)
                      const ListenTogetherMemberBadge(label: 'You'),
                  ],
                ),
                subtitle: Text(
                  [
                    if ((entry.value.deviceLabel ?? '').isNotEmpty)
                      entry.value.deviceLabel!,
                    _presenceLabel(entry.value.presenceState),
                  ].join(' · '),
                ),
                trailing:
                    canTransferHost &&
                        entry.value.memberId != room.self.memberId &&
                        entry.value.presenceState ==
                            GroupListeningMemberPresenceState.active
                    ? TextButton(
                        key: ValueKey(
                          'groupListeningTransferHostButton-${entry.value.memberId}',
                        ),
                        onPressed: () => _transferHost(entry.value),
                        child: const Text('Make host'),
                      )
                    : null,
              ),
            ],
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
      groupListeningQueueTrackSkippedProvider,
      (previous, next) {
        if (previous != null && next > previous && mounted) {
          showAppNotice(
            context,
            message: 'Skipped — not available on your library.',
            level: AppNoticeLevel.info,
          );
        }
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
        if (sessionState.hasActiveRoom) ...<Widget>[
          _buildConnectedUsersCard(sessionState),
          const SizedBox(height: 12),
        ],
        _buildActionsCard(sessionState, clientDescriptor),
        const SizedBox(height: 12),
        _buildAvailableRoomsCard(
          sessionState,
          clientDescriptor,
          availableRooms,
        ),
        const SizedBox(height: 12),
        Card(
          child: SwitchListTile.adaptive(
            key: const ValueKey('groupListeningAutoFollowHostToggle'),
            title: const Text('Auto-follow host playback'),
            subtitle: const Text(
              'When enabled, your player follows the room anchor after remote changes.',
            ),
            value: ref.watch(
              groupListeningSettingsProvider.select(
                (settings) => settings.autoFollowHost,
              ),
            ),
            onChanged: _isBusy(sessionState) ? null : _toggleAutoFollowHost,
          ),
        ),
      ],
    );
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
