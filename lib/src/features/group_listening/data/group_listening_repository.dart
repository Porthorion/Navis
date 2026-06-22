export 'group_listening_credential_store.dart';
export 'group_listening_dtos.dart';
export 'group_listening_http_client.dart';
export 'group_listening_transport_messages.dart';
export 'group_listening_wire_codec.dart';
export 'group_listening_ws_transport.dart';

import 'package:navis/src/features/group_listening/data/group_listening_dtos.dart';
import 'package:navis/src/features/group_listening/data/group_listening_http_client.dart';
import 'package:navis/src/features/group_listening/data/group_listening_transport_messages.dart';
import 'package:navis/src/features/group_listening/data/group_listening_ws_transport.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

abstract class GroupListeningRepository {
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  );

  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  );

  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  );

  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
    String? pinCode,
  });

  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  );

  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  );

  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  });

  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  });

  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  });

  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  });

  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  );
}

class DefaultGroupListeningRepository implements GroupListeningRepository {
  const DefaultGroupListeningRepository({
    required GroupListeningHttpClient httpClient,
    required GroupListeningRealtimeTransportClient realtimeTransport,
  }) : _httpClient = httpClient,
       _realtimeTransport = realtimeTransport;

  final GroupListeningHttpClient _httpClient;
  final GroupListeningRealtimeTransportClient _realtimeTransport;

  @override
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  ) {
    return _realtimeTransport.connect(request);
  }

  @override
  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  ) {
    return _httpClient.createRoom(request);
  }

  @override
  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  ) {
    return _httpClient.listAvailableRooms(configuration);
  }

  @override
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  ) {
    return _httpClient.discover(configuration);
  }

  @override
  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
    String? pinCode,
  }) {
    return _httpClient.joinAvailableRoom(
      roomId: roomId,
      configuration: configuration,
      client: client,
      pinCode: pinCode,
    );
  }

  @override
  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) {
    return _httpClient.fetchSnapshot(
      session,
      lastAppliedRoomVersion: lastAppliedRoomVersion,
    );
  }

  @override
  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  ) {
    return _httpClient.joinRoom(request);
  }

  @override
  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) {
    return _httpClient.leaveRoom(
      session,
      lastAppliedRoomVersion: lastAppliedRoomVersion,
    );
  }

  @override
  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  ) {
    return _httpClient.rejoinRoom(request);
  }

  @override
  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
    return _httpClient.closeRoom(
      session,
      expectedRoomVersion: expectedRoomVersion,
    );
  }

  @override
  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
    return _httpClient.rotateInvite(
      session,
      expectedRoomVersion: expectedRoomVersion,
    );
  }
}
