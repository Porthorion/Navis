import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_pending_mutation_policy.dart';
import 'package:navis/src/utils/app_logger.dart';

@immutable
class PendingGroupListeningMutation {
  const PendingGroupListeningMutation({
    required this.type,
    required this.clientMutationId,
    this.playbackAnchor,
    this.queue,
    this.targetQueueEntryId,
    this.insertIndex,
    this.targetMemberId,
    this.clientSequence,
  });

  final GroupListeningMutationType type;
  final String clientMutationId;
  final GroupListeningPlaybackAnchor? playbackAnchor;
  final GroupListeningQueueState? queue;
  final String? targetQueueEntryId;
  final int? insertIndex;
  final String? targetMemberId;
  final int? clientSequence;

  PendingGroupListeningMutation copyWith({int? clientSequence}) {
    return PendingGroupListeningMutation(
      type: type,
      clientMutationId: clientMutationId,
      playbackAnchor: playbackAnchor,
      queue: queue,
      targetQueueEntryId: targetQueueEntryId,
      insertIndex: insertIndex,
      targetMemberId: targetMemberId,
      clientSequence: clientSequence ?? this.clientSequence,
    );
  }

  PendingGroupListeningMutation withoutSequence() {
    return PendingGroupListeningMutation(
      type: type,
      clientMutationId: clientMutationId,
      playbackAnchor: playbackAnchor,
      queue: queue,
      targetQueueEntryId: targetQueueEntryId,
      insertIndex: insertIndex,
      targetMemberId: targetMemberId,
    );
  }
}

typedef GroupListeningMutationSender =
    Future<void> Function(
      PendingGroupListeningMutation mutation,
      GroupListeningMutationMessage message,
    );

/// Queues, coalesces, and dispatches outbound room mutations.
class GroupListeningMutationOutbox {
  GroupListeningMutationOutbox({
    required GroupListeningMutationSender send,
    required bool Function(GroupListeningMutationType type) canSendType,
    required int? Function(
      GroupListeningMutationType type, {
      GroupListeningPlaybackAnchor? playbackAnchor,
    })
    expectedQueueVersion,
    required int? Function(
      GroupListeningMutationType type, {
      GroupListeningPlaybackAnchor? playbackAnchor,
    })
    expectedPlaybackVersion,
    required int Function() expectedPlaybackEpoch,
    required int Function() nextClientSequence,
    required String? Function() readClientConnectionId,
    required bool Function() isConnected,
    required int Function() readLastAppliedRoomVersion,
    GroupListeningPendingMutationPolicy? pendingPolicy,
    void Function(
      PendingGroupListeningMutation mutation,
      Object error,
      StackTrace stackTrace,
    )?
    onSendError,
  }) : _send = send,
       _canSendType = canSendType,
       _expectedQueueVersion = expectedQueueVersion,
       _expectedPlaybackVersion = expectedPlaybackVersion,
       _expectedPlaybackEpoch = expectedPlaybackEpoch,
       _nextClientSequence = nextClientSequence,
       _readClientConnectionId = readClientConnectionId,
       _isConnected = isConnected,
       _readLastAppliedRoomVersion = readLastAppliedRoomVersion,
       _pendingPolicy =
           pendingPolicy ?? const GroupListeningPendingMutationPolicy(),
       _onSendError = onSendError;

  final GroupListeningMutationSender _send;
  final bool Function(GroupListeningMutationType type) _canSendType;
  final int? Function(
    GroupListeningMutationType type, {
    GroupListeningPlaybackAnchor? playbackAnchor,
  })
  _expectedQueueVersion;
  final int? Function(
    GroupListeningMutationType type, {
    GroupListeningPlaybackAnchor? playbackAnchor,
  })
  _expectedPlaybackVersion;
  final int Function() _expectedPlaybackEpoch;
  final int Function() _nextClientSequence;
  final String? Function() _readClientConnectionId;
  final bool Function() _isConnected;
  final int Function() _readLastAppliedRoomVersion;
  final GroupListeningPendingMutationPolicy _pendingPolicy;
  final void Function(
    PendingGroupListeningMutation mutation,
    Object error,
    StackTrace stackTrace,
  )?
  _onSendError;

  final List<PendingGroupListeningMutation> _pending =
      <PendingGroupListeningMutation>[];
  PendingGroupListeningMutation? _inFlight;
  bool _paused = false;
  bool _dispatching = false;

  List<PendingGroupListeningMutation> get pending =>
      List<PendingGroupListeningMutation>.unmodifiable(_pending);

  PendingGroupListeningMutation? get inFlight => _inFlight;

  void pause() => _paused = true;

  void resume() {
    _paused = false;
    dispatch();
  }

  void clear() {
    _pending.clear();
    _inFlight = null;
    _dispatching = false;
    _paused = false;
  }

  void dropPendingPlaybackMutations() {
    _pending.removeWhere(_pendingPolicy.isObsoletePlaybackMutation);
  }

  void revalidateAgainstSnapshot(GroupListeningRoomState snapshot) {
    _pending.removeWhere(
      (mutation) => !_pendingPolicy.shouldRetain(mutation, snapshot),
    );
  }

  void insertAtFront(PendingGroupListeningMutation mutation) {
    _pending.insert(0, mutation);
  }

  void enqueue(PendingGroupListeningMutation mutation) {
    switch (mutation.type) {
      case GroupListeningMutationType.playbackAnchor:
        _pending.removeWhere(
          (pending) =>
              pending.type == GroupListeningMutationType.playbackAnchor,
        );
      case GroupListeningMutationType.queueReplace:
        _pending.removeWhere(
          (pending) =>
              pending.type == GroupListeningMutationType.queueAdd ||
              pending.type == GroupListeningMutationType.queueRemove ||
              pending.type == GroupListeningMutationType.queueReplace,
        );
      case GroupListeningMutationType.queueAdd:
      case GroupListeningMutationType.queueRemove:
      case GroupListeningMutationType.transferHost:
      case GroupListeningMutationType.removeMember:
    }
    _pending.add(mutation);
    AppLogger.debug(
      'Group listening mutation queued: '
      'id=${mutation.clientMutationId}, type=${mutation.type.name}, '
      'pending=${_pending.length}, in_flight=${_inFlight?.clientMutationId ?? 'none'}',
    );
    dispatch();
  }

  void dispatch() {
    if (_dispatching || _paused || _inFlight != null || _pending.isEmpty) {
      return;
    }
    final clientConnectionId = _readClientConnectionId();
    if (clientConnectionId == null || !_isConnected()) {
      return;
    }

    final mutation = _pending.removeAt(0);
    if (!_canSendType(mutation.type)) {
      dispatch();
      return;
    }

    final clientSequence = _nextClientSequence();
    final message = GroupListeningMutationMessage(
      type: mutation.type,
      expectedRoomVersion: _readLastAppliedRoomVersion(),
      expectedQueueVersion: _expectedQueueVersion(
        mutation.type,
        playbackAnchor: mutation.playbackAnchor,
      ),
      expectedPlaybackVersion: _expectedPlaybackVersion(
        mutation.type,
        playbackAnchor: mutation.playbackAnchor,
      ),
      expectedPlaybackEpoch: _expectedPlaybackEpoch(),
      clientMutationId: mutation.clientMutationId,
      clientConnectionId: clientConnectionId,
      clientSequence: clientSequence,
      playbackAnchor: mutation.playbackAnchor,
      queue: mutation.queue,
      targetQueueEntryId: mutation.targetQueueEntryId,
      insertIndex: mutation.insertIndex,
      targetMemberId: mutation.targetMemberId,
    );
    _inFlight = mutation.copyWith(clientSequence: clientSequence);
    _dispatching = true;
    AppLogger.info(
      'Group listening mutation sending: '
      'id=${mutation.clientMutationId}, type=${mutation.type.name}, '
      'connection=$clientConnectionId, seq=$clientSequence, '
      'room_version=${message.expectedRoomVersion}, '
      'queue_version=${message.expectedQueueVersion ?? 0}, '
      'playback_version=${message.expectedPlaybackVersion ?? 0}',
    );
    unawaited(
      _send(_inFlight!, message)
          .catchError((Object error, StackTrace stackTrace) {
            _inFlight = null;
            _pending.insert(0, mutation);
            _onSendError?.call(mutation, error, stackTrace);
          })
          .whenComplete(() {
            _dispatching = false;
            dispatch();
          }),
    );
  }

  void handleAck(String clientMutationId) {
    final inFlight = _inFlight;
    if (inFlight == null || inFlight.clientMutationId != clientMutationId) {
      _pending.removeWhere(
        (pending) => pending.clientMutationId == clientMutationId,
      );
      return;
    }
    AppLogger.info(
      'Group listening mutation ack: '
      'id=$clientMutationId, type=${inFlight.type.name}',
    );
    _inFlight = null;
    dispatch();
  }

  void handleDuplicateAck(String clientMutationId) {
    _pending.removeWhere(
      (pending) => pending.clientMutationId == clientMutationId,
    );
    if (_inFlight?.clientMutationId == clientMutationId) {
      _inFlight = null;
    }
    dispatch();
  }

  void handleNack({String? clientMutationId, bool dropInFlight = true}) {
    if (clientMutationId != null && clientMutationId.isNotEmpty) {
      _pending.removeWhere(
        (pending) => pending.clientMutationId == clientMutationId,
      );
    }
    if (dropInFlight &&
        (clientMutationId == null ||
            clientMutationId.isEmpty ||
            _inFlight?.clientMutationId == clientMutationId)) {
      _inFlight = null;
    }
    dispatch();
  }

  PendingGroupListeningMutation? takeInFlightForNack(String? clientMutationId) {
    final inFlight = _inFlight;
    if (inFlight == null) {
      return null;
    }
    final applies =
        clientMutationId == null ||
        clientMutationId.isEmpty ||
        inFlight.clientMutationId == clientMutationId;
    if (!applies) {
      return null;
    }
    return inFlight;
  }

  void clearInFlight() {
    _inFlight = null;
  }

  void abortInFlightTransport() {
    _inFlight = null;
    _dispatching = false;
  }

  void requeueInFlightWithoutSequence() {
    final inFlight = _inFlight;
    if (inFlight == null) {
      return;
    }
    _inFlight = null;
    _pending.insert(0, inFlight.withoutSequence());
    dispatch();
  }
}
