import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';

/// Room lifecycle helpers extracted from the session controller.
class GroupListeningSessionLifecycle {
  const GroupListeningSessionLifecycle(this.ref);

  final Ref ref;

  GroupListeningSessionController get _controller =>
      ref.read(groupListeningSessionControllerProvider.notifier);

  Future<GroupListeningSessionState> createRoom({
    required GroupListeningClientDescriptor client,
    GroupListeningRoomOptions roomOptions = const GroupListeningRoomOptions(),
    GroupListeningRoomSeed? roomSeed,
    bool connectAfterCreate = true,
  }) {
    return _controller.createRoom(
      client: client,
      roomOptions: roomOptions,
      roomSeed: roomSeed,
      connectAfterCreate: connectAfterCreate,
    );
  }

  Future<GroupListeningSessionState> joinRoom({
    required String inviteCode,
    required GroupListeningClientDescriptor client,
    String? pinCode,
    bool connectAfterJoin = true,
  }) {
    return _controller.joinRoom(
      inviteCode: inviteCode,
      client: client,
      pinCode: pinCode,
      connectAfterJoin: connectAfterJoin,
    );
  }

  Future<GroupListeningSessionState> leaveRoom({
    bool disconnectTransport = true,
  }) {
    return _controller.leaveRoom(disconnectTransport: disconnectTransport);
  }

  Future<GroupListeningSessionState> closeRoom() {
    return _controller.closeRoom();
  }

  Future<void> restoreStoredSessionIfAvailable() {
    return _controller.restoreStoredSessionIfAvailable();
  }
}

final groupListeningSessionLifecycleProvider =
    Provider<GroupListeningSessionLifecycle>((ref) {
      return GroupListeningSessionLifecycle(ref);
    });
