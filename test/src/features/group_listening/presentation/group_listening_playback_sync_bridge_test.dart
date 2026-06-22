import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_sync_bridge.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _FakeGroupListeningRepository implements GroupListeningRepository {
  GroupListeningJoinResponse? joinResponse;
  GroupListeningRoomState? snapshotResponse;
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
  ) {
    throw UnimplementedError();
  }

  @override
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  ) {
    return Future<GroupListeningCapabilityDiscovery>.value(
      const GroupListeningCapabilityDiscovery(
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
      ),
    );
  }

  @override
  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
    String? pinCode,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) async {
    return snapshotResponse!;
  }

  @override
  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  ) async {
    return joinResponse!;
  }

  @override
  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
    throw UnimplementedError();
  }
}

class _FakeRealtimeConnection implements GroupListeningRealtimeConnection {
  final _controller =
      StreamController<GroupListeningTransportMessage>.broadcast();
  final sentMessages = <GroupListeningOutboundTransportMessage>[];
  Object? nextSendError;

  @override
  Stream<GroupListeningTransportMessage> get messages => _controller.stream;

  void add(GroupListeningTransportMessage message) {
    _controller.add(message);
  }

  @override
  Future<void> disconnect() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  @override
  Future<void> send(GroupListeningOutboundTransportMessage message) async {
    final error = nextSendError;
    if (error != null) {
      nextSendError = null;
      throw error;
    }
    sentMessages.add(message);
  }
}

class _ReplaceQueueCall {
  const _ReplaceQueueCall({
    required this.songIds,
    required this.startIndex,
    required this.autoPlay,
  });

  final List<String> songIds;
  final int startIndex;
  final bool autoPlay;
}

class _FakePlaybackHandler implements NavisPlaybackHandler {
  _FakePlaybackHandler(this._snapshot);

  final _snapshotController = StreamController<PlaybackSnapshot>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  PlaybackSnapshot _snapshot;

  final replaceQueueCalls = <_ReplaceQueueCall>[];
  final seekCalls = <Duration>[];
  final addToQueueCalls = <List<String>>[];
  int clearQueueCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  Completer<void>? replaceQueueCompleter;
  Object? replaceQueueError;
  int maxConcurrentReplaceQueueCalls = 0;
  int _activeReplaceQueueCalls = 0;

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  Stream<ManualTrackChangeCue> get manualTrackChangeCueStream =>
      const Stream<ManualTrackChangeCue>.empty();

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  MediaItem? get currentMediaItem => null;

  @override
  Stream<MediaItem?> get mediaItemStream => const Stream<MediaItem?>.empty();

  @override
  Stream<PlaybackLoadFailure> get loadFailureStream =>
      const Stream<PlaybackLoadFailure>.empty();

  @override
  Stream<void> get radioStreamErrorStream => const Stream<void>.empty();

  @override
  Future<void> waitUntilReady() async {}

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) async {
    _activeReplaceQueueCalls += 1;
    if (_activeReplaceQueueCalls > maxConcurrentReplaceQueueCalls) {
      maxConcurrentReplaceQueueCalls = _activeReplaceQueueCalls;
    }
    replaceQueueCalls.add(
      _ReplaceQueueCall(
        songIds: List<String>.unmodifiable(songIds),
        startIndex: startIndex,
        autoPlay: autoPlay,
      ),
    );
    try {
      final completer = replaceQueueCompleter;
      if (completer != null) {
        await completer.future;
      }
      final error = replaceQueueError;
      if (error != null) {
        replaceQueueError = null;
        throw error;
      }
      final normalizedIndex = songIds.isEmpty
          ? null
          : (startIndex < 0
                ? 0
                : (startIndex >= songIds.length
                      ? songIds.length - 1
                      : startIndex));
      final currentSongId = normalizedIndex == null
          ? null
          : songIds[normalizedIndex];
      _emit(
        PlaybackSnapshot(
          queueSongIds: List<String>.unmodifiable(songIds),
          currentSongId: currentSongId,
          currentIndex: normalizedIndex,
          playing: autoPlay && songIds.isNotEmpty,
          processingState: AudioProcessingState.ready,
          position: Duration.zero,
          duration: Duration.zero,
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
        ),
      );
    } finally {
      _activeReplaceQueueCalls -= 1;
    }
  }

  @override
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) {
    return replaceQueue(
      songs.map((song) => song.id).toList(growable: false),
      startIndex: startIndex,
      autoPlay: autoPlay,
    );
  }

  @override
  Future<void> addToQueue(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {
    addToQueueCalls.add(List<String>.unmodifiable(songIds));
    final nextQueue = <String>[..._snapshot.queueSongIds, ...songIds];
    final currentIndex =
        _snapshot.currentIndex ?? (nextQueue.isEmpty ? null : 0);
    _emit(
      _snapshot.copyWith(
        queueSongIds: List<String>.unmodifiable(nextQueue),
        currentIndex: currentIndex,
        currentSongId: currentIndex == null ? null : nextQueue[currentIndex],
      ),
    );
  }

  @override
  Future<void> playNext(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {}

  @override
  Future<void> playFromIndex(int index) async {
    if (index < 0 || index >= _snapshot.queueSongIds.length) {
      return;
    }
    _emit(
      _snapshot.copyWith(
        currentIndex: index,
        currentSongId: _snapshot.queueSongIds[index],
        position: Duration.zero,
        playing: true,
      ),
    );
  }

  @override
  Future<void> removeAt(int index) async {}

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) async {}

  @override
  Future<void> clearQueue() async {
    clearQueueCalls += 1;
    _emit(const PlaybackSnapshot.idle());
  }

  @override
  Future<void> play() async {
    playCalls += 1;
    _emit(_snapshot.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    _emit(_snapshot.copyWith(playing: false));
  }

  @override
  Future<void> stop() async {
    await pause();
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
    _emit(_snapshot.copyWith(position: position));
  }

  void updatePosition(Duration position) {
    _emit(_snapshot.copyWith(position: position));
  }

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {}

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {}

  @override
  Future<void> setPlaybackSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> applyRuntimeSettings() async {}

  @override
  Future<void> toggleLike() async {}

  @override
  Future<void> syncSongLikedState(String songId, {required bool liked}) async {}

  @override
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  }) async {}

  @override
  Future<void> stopRadio() async {}

  @override
  void updateRadioMetadata({String? title, String? artist, String? artUrl}) {}

  @override
  void registerPreferredMixCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}

  @override
  void registerPreferredMixToggleCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}

  void clearInteractionLog() {
    replaceQueueCalls.clear();
    seekCalls.clear();
    addToQueueCalls.clear();
    clearQueueCalls = 0;
    playCalls = 0;
    pauseCalls = 0;
    maxConcurrentReplaceQueueCalls = 0;
  }

  Future<void> dispose() async {
    await _snapshotController.close();
    await _positionController.close();
  }

  void _emit(PlaybackSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshotController.add(snapshot);
    _positionController.add(snapshot.position);
  }
}

void main() {
  const activeServer = ServerConfigModel(
    url: 'https://Sub.Example.com/navidrome/',
    username: 'alice',
    password: 'secret',
    apiVersion: '1.16.1',
  );
  const client = GroupListeningClientDescriptor(
    appVersion: '1.0.0',
    platform: 'linux',
    deviceId: 'device-1',
    deviceLabel: 'Desktop',
    capabilities: <String>{'playback_anchor'},
  );

  ProviderContainer createContainer({
    required GroupListeningRepository repository,
    required NavisPlaybackHandler handler,
    bool autoFollowHost = true,
  }) {
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          AsyncData<AppSettingsModel>(
            AppSettingsModel.defaults().copyWith(
              groupListeningEnabled: true,
              voyageServerUrl: 'https://voyage.example.com',
              voyageDeviceLabel: 'Desktop',
              voyageAutoFollowHost: autoFollowHost,
              clearVoyageDisplayName: true,
            ),
          ),
        ),
        serverConfigStateProvider.overrideWithValue(
          const AsyncData(activeServer),
        ),
        groupListeningRepositoryProvider.overrideWithValue(repository),
        audioHandlerProvider.overrideWithValue(handler),
        subsonicApiProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('groupListeningPlaybackSyncBridgeProvider', () {
    test(
      'publishes local queue changes upstream as queue replace mutations',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();
        connection.sentMessages.clear();
        handler.clearInteractionLog();

        await container
            .read(queueProvider.notifier)
            .replace(
              const <String>['song-1', 'song-2'],
              startIndex: 1,
              autoPlay: true,
            );
        await _pumpBridge();

        expect(connection.sentMessages, hasLength(1));
        final message =
            connection.sentMessages.single as GroupListeningMutationMessage;
        expect(message.type, GroupListeningMutationType.queueReplace);
        expect(message.clientSequence, 1);
        expect(
          message.queue?.entries.map((entry) => entry.songId).toList(),
          const <String>['song-1', 'song-2'],
        );
        expect(message.playbackAnchor?.currentIndex, 1);
        expect(message.playbackAnchor?.currentSongId, 'song-2');
        expect(
          message.playbackAnchor?.reason,
          GroupListeningPlaybackAnchorReason.trackChange,
        );
      },
    );

    test(
      'publishes shared queue mutations even when the local member follows host playback',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room =
            _roomState(
              fingerprint: fingerprint,
              roomVersion: 1,
              queueSongIds: const <String>['song-1'],
              currentIndex: 0,
              playbackState: GroupListeningPlaybackStatus.paused,
              position: const Duration(seconds: 15),
              issuedByMemberId: 'member-1',
            ).copyWith(
              hostMemberId: 'member-1',
              self: const GroupListeningSelfState(
                memberId: 'member-2',
                role: GroupListeningMemberRole.member,
                canControl: true,
                authVersion: 1,
              ),
            );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: GroupListeningSessionRuntimeContext(
            roomId: 'room-1',
            memberId: 'member-2',
            role: GroupListeningMemberRole.member,
            authVersion: 1,
            voyageBaseUrl: Uri.parse('https://voyage.example.com'),
            sourceServerFingerprint: fingerprint,
            accessToken: 'access-token',
            accessTokenExpiresAt: DateTime.now().toUtc().add(
              const Duration(hours: 1),
            ),
            rejoinToken: 'rejoin-token',
          ),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(
          GroupListeningConnectionWelcomeMessage(
            roomId: 'room-1',
            memberId: 'member-2',
            clientConnectionId: 'conn-2',
            roomVersion: 1,
            presenceVersion: 1,
            heartbeatInterval: const Duration(seconds: 10),
            memberStaleTimeout: const Duration(seconds: 45),
            serverTime: DateTime.utc(2026, 4, 21, 12),
          ),
        );
        await _pumpBridge();
        connection.sentMessages.clear();

        await container.read(queueProvider.notifier).add('song-2');
        await _pumpBridge();

        expect(connection.sentMessages, hasLength(1));
        final message =
            connection.sentMessages.single as GroupListeningMutationMessage;
        expect(message.type, GroupListeningMutationType.queueAdd);
        expect(
          message.queue?.entries.map((entry) => entry.songId).toList(),
          const <String>['song-2'],
        );
        expect(
          message.targetQueueEntryId,
          message.queue?.entries.single.queueEntryId,
        );
        expect(handler.addToQueueCalls, isEmpty);
      },
    );

    test(
      'publishes playback mutations for collaborative room members',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
          selfRole: GroupListeningMemberRole.member,
          selfCanControl: true,
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(
            fingerprint: fingerprint,
            role: GroupListeningMemberRole.member,
          ),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(
          GroupListeningConnectionWelcomeMessage(
            roomId: 'room-1',
            memberId: 'member-2',
            clientConnectionId: 'conn-2',
            roomVersion: 1,
            presenceVersion: 1,
            heartbeatInterval: const Duration(seconds: 10),
            memberStaleTimeout: const Duration(seconds: 45),
            serverTime: DateTime.utc(2026, 4, 21, 12),
          ),
        );
        await _pumpBridge();
        connection.sentMessages.clear();

        await handler.play();
        await _pumpBridge();

        expect(connection.sentMessages, hasLength(1));
        final message =
            connection.sentMessages.single as GroupListeningMutationMessage;
        expect(message.type, GroupListeningMutationType.playbackAnchor);
        expect(
          message.playbackAnchor?.playbackState,
          GroupListeningPlaybackStatus.playing,
        );
        expect(
          message.playbackAnchor?.issuedByMemberId,
          'member-2',
        );
        expect(
          message.playbackAnchor?.issuedByConnectionId,
          'conn-2',
        );
      },
    );

    test(
      'does not publish a mutation for projected passive playback progression',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.playing,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(
          _welcome(
            roomVersion: 1,
            serverTime: room.playbackAnchor!.capturedAt.add(
              const Duration(milliseconds: 800),
            ),
          ),
        );
        await _pumpBridge();
        connection.sentMessages.clear();

        await Future<void>.delayed(const Duration(milliseconds: 650));
        handler.updatePosition(const Duration(milliseconds: 16450));
        await _pumpBridge();

        expect(connection.sentMessages, isEmpty);
      },
    );

    test(
      'applies inbound room events through queue and playback seams',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
        );
        final handler = _FakePlaybackHandler(const PlaybackSnapshot.idle());
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();
        handler.clearInteractionLog();

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(
              roomVersion: 2,
              previousRoomVersion: 1,
              queueSongIds: const <String>['song-1', 'song-2'],
              currentIndex: 1,
              playbackState: GroupListeningPlaybackStatus.playing,
              position: const Duration(seconds: 25),
              issuedByMemberId: 'member-2',
            ),
          ),
        );
        await _pumpBridge();

        expect(handler.replaceQueueCalls, hasLength(1));
        final call = handler.replaceQueueCalls.single;
        expect(call.songIds, const <String>['song-1', 'song-2']);
        expect(call.startIndex, 1);
        expect(call.autoPlay, isTrue);
        expect(handler.seekCalls, contains(const Duration(seconds: 25)));
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(handler.snapshot.playing, isTrue);
      },
    );

    test(
      'does not seek when a queue-only event keeps the playback anchor unchanged',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.playing,
          position: const Duration(seconds: 10),
          issuedByMemberId: 'member-1',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();
        handler.updatePosition(const Duration(seconds: 30));
        handler.clearInteractionLog();

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(
              roomVersion: 2,
              previousRoomVersion: 1,
              queueSongIds: const <String>['song-1', 'song-2'],
              currentIndex: 0,
              playbackState: GroupListeningPlaybackStatus.playing,
              position: const Duration(seconds: 10),
              issuedByMemberId: 'member-2',
              includePlaybackAnchor: false,
              eventType: GroupListeningRoomEventType.queueAdd,
            ),
          ),
        );
        await _pumpBridge();

        expect(handler.addToQueueCalls, const <List<String>>[
          <String>['song-2'],
        ]);
        expect(handler.replaceQueueCalls, isEmpty);
        expect(handler.seekCalls, isEmpty);
        expect(handler.playCalls, 0);
        expect(handler.pauseCalls, 0);
        expect(handler.snapshot.queueSongIds, const <String>[
          'song-1',
          'song-2',
        ]);
      },
    );

    test(
      'self-issued queue add echo appends locally without playback correction',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.playing,
          position: const Duration(seconds: 10),
          issuedByMemberId: 'member-1',
          issuedByConnectionId: 'conn-1',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();
        connection.sentMessages.clear();

        await container.read(queueProvider.notifier).add('song-2');
        await _pumpBridge();
        expect(connection.sentMessages, hasLength(1));
        handler.updatePosition(const Duration(seconds: 30));
        handler.clearInteractionLog();
        connection.sentMessages.clear();

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(
              roomVersion: 2,
              previousRoomVersion: 1,
              queueSongIds: const <String>['song-1', 'song-2'],
              currentIndex: 0,
              playbackState: GroupListeningPlaybackStatus.playing,
              position: const Duration(seconds: 10),
              issuedByMemberId: 'member-1',
              includePlaybackAnchor: false,
              eventType: GroupListeningRoomEventType.queueAdd,
            ),
          ),
        );
        await _pumpBridge();

        expect(handler.addToQueueCalls, const <List<String>>[
          <String>['song-2'],
        ]);
        expect(handler.replaceQueueCalls, isEmpty);
        expect(handler.seekCalls, isEmpty);
        expect(handler.playCalls, 0);
        expect(handler.pauseCalls, 0);
      },
    );

    test(
      'serializes overlapping inbound playback applies',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        handler.replaceQueueCompleter = Completer<void>();
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();
        handler.clearInteractionLog();

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(
              roomVersion: 2,
              previousRoomVersion: 1,
              queueSongIds: const <String>['song-1', 'song-2'],
              currentIndex: 1,
              playbackState: GroupListeningPlaybackStatus.playing,
              position: const Duration(seconds: 25),
              issuedByMemberId: 'member-2',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(
              roomVersion: 3,
              previousRoomVersion: 2,
              queueSongIds: const <String>['song-1', 'song-2', 'song-3'],
              currentIndex: 2,
              playbackState: GroupListeningPlaybackStatus.playing,
              position: const Duration(seconds: 40),
              issuedByMemberId: 'member-2',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        handler.replaceQueueCompleter?.complete();
        handler.replaceQueueCompleter = null;
        await _pumpBridge();

        expect(handler.maxConcurrentReplaceQueueCalls, 1);
        expect(handler.replaceQueueCalls, hasLength(2));
        expect(
          handler.replaceQueueCalls.last.songIds,
          const <String>['song-1', 'song-2', 'song-3'],
        );
        expect(handler.snapshot.currentSongId, 'song-3');
      },
    );

    test(
      'ignores benign loading interruptions during inbound playback apply',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        handler.replaceQueueError = StateError('Loading interrupted');
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final capturedFlutterErrors = <FlutterErrorDetails>[];
        final previousOnError = FlutterError.onError;
        FlutterError.onError = capturedFlutterErrors.add;
        addTearDown(() => FlutterError.onError = previousOnError);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();
        handler.clearInteractionLog();

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(
              roomVersion: 2,
              previousRoomVersion: 1,
              queueSongIds: const <String>['song-1', 'song-2'],
              currentIndex: 1,
              playbackState: GroupListeningPlaybackStatus.playing,
              position: const Duration(seconds: 25),
              issuedByMemberId: 'member-2',
            ),
          ),
        );
        await _pumpBridge();

        expect(capturedFlutterErrors, isEmpty);
      },
    );

    test(
      'does not apply remote playback control when auto follow is disabled',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
          autoFollowHost: false,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();
        handler.clearInteractionLog();

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(
              roomVersion: 2,
              previousRoomVersion: 1,
              queueSongIds: const <String>['song-1', 'song-2'],
              currentIndex: 1,
              playbackState: GroupListeningPlaybackStatus.playing,
              position: const Duration(seconds: 25),
              issuedByMemberId: 'member-2',
            ),
          ),
        );
        await _pumpBridge();

        expect(handler.snapshot.queueSongIds, const <String>[
          'song-1',
          'song-2',
        ]);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.snapshot.playing, isFalse);
        expect(handler.seekCalls, isEmpty);
        expect(handler.playCalls, 0);
        expect(handler.pauseCalls, 0);
      },
    );

    test(
      'ignores echoed self-issued room events that already match local playback',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();

        await handler.replaceQueue(
          const <String>['song-1', 'song-2'],
          startIndex: 1,
          autoPlay: true,
        );
        await _pumpBridge();
        handler.clearInteractionLog();

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(
              roomVersion: 2,
              previousRoomVersion: 1,
              queueSongIds: const <String>['song-1', 'song-2'],
              currentIndex: 1,
              playbackState: GroupListeningPlaybackStatus.playing,
              position: Duration.zero,
              issuedByMemberId: 'member-1',
              issuedByConnectionId: 'conn-1',
            ),
          ),
        );
        await _pumpBridge();

        expect(handler.replaceQueueCalls, isEmpty);
        expect(handler.seekCalls, isEmpty);
        expect(handler.playCalls, 0);
        expect(handler.pauseCalls, 0);
      },
    );

    test(
      'applies playback updates from a different connection of the same member',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.connection = connection;
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();
        handler.clearInteractionLog();

        connection.add(
          GroupListeningRoomEventMessage(
            _roomEvent(
              roomVersion: 2,
              previousRoomVersion: 1,
              queueSongIds: const <String>['song-1'],
              currentIndex: 0,
              playbackState: GroupListeningPlaybackStatus.playing,
              position: const Duration(seconds: 20),
              issuedByMemberId: 'member-1',
              issuedByConnectionId: 'conn-rejoined',
            ),
          ),
        );
        await _pumpBridge();

        expect(handler.playCalls, 1);
        expect(handler.seekCalls, contains(const Duration(seconds: 20)));
        expect(handler.snapshot.playing, isTrue);
      },
    );

    test(
      'refreshes the authoritative snapshot after a stale-version rejection',
      () async {
        final repository = _FakeGroupListeningRepository();
        final connection = _FakeRealtimeConnection();
        final fingerprint = computeSourceServerFingerprint(activeServer.url);
        final room = _roomState(
          fingerprint: fingerprint,
          roomVersion: 1,
          queueSongIds: const <String>['song-1'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 15),
          issuedByMemberId: 'member-1',
        );
        final refreshedRoom = _roomState(
          fingerprint: fingerprint,
          roomVersion: 2,
          queueSongIds: const <String>['song-3'],
          currentIndex: 0,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: const Duration(seconds: 5),
          issuedByMemberId: 'member-2',
        );
        final handler = _FakePlaybackHandler(_snapshotFromRoom(room));
        repository.joinResponse = GroupListeningJoinResponse(
          runtimeContext: _runtimeContext(fingerprint: fingerprint),
          roomSnapshot: room,
        );
        repository.snapshotResponse = refreshedRoom;
        repository.connection = connection;
        connection.nextSendError = const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.staleVersion,
            message: 'stale version',
            retryable: true,
            roomVersion: 2,
          ),
        );
        addTearDown(handler.dispose);

        final container = createContainer(
          repository: repository,
          handler: handler,
        );
        final bridgeSubscription = container.listen(
          groupListeningPlaybackSyncBridgeProvider,
          (_, __) {},
        );
        addTearDown(bridgeSubscription.close);
        final controller = container.read(
          groupListeningSessionControllerProvider.notifier,
        );

        await controller.joinRoom(
          inviteCode: 'INVITE',
          client: client,
          connectAfterJoin: false,
        );
        await controller.connect();
        connection.add(_welcome(roomVersion: 1));
        await _pumpBridge();

        await container
            .read(queueProvider.notifier)
            .replace(const <String>['song-2'], startIndex: 0, autoPlay: false);
        await _pumpBridge();
        await _pumpBridge();

        final state = container.read(groupListeningSessionControllerProvider);
        expect(state.snapshotRequired, isFalse);
        expect(state.room?.roomVersion, 2);
        expect(handler.snapshot.currentSongId, 'song-3');
        expect(handler.seekCalls, contains(const Duration(seconds: 5)));
      },
    );
  });
}

Future<void> _pumpBridge() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

GroupListeningConnectionWelcomeMessage _welcome({
  required int roomVersion,
  DateTime? serverTime,
}) {
  return GroupListeningConnectionWelcomeMessage(
    roomId: 'room-1',
    memberId: 'member-1',
    clientConnectionId: 'conn-1',
    roomVersion: roomVersion,
    presenceVersion: 1,
    heartbeatInterval: const Duration(seconds: 10),
    memberStaleTimeout: const Duration(seconds: 45),
    serverTime: serverTime ?? DateTime.utc(2026, 4, 21, 12),
  );
}

GroupListeningSessionRuntimeContext _runtimeContext({
  required String fingerprint,
  GroupListeningMemberRole role = GroupListeningMemberRole.host,
}) {
  final memberId = role == GroupListeningMemberRole.host
      ? 'member-1'
      : 'member-2';
  return GroupListeningSessionRuntimeContext(
    roomId: 'room-1',
    memberId: memberId,
    role: role,
    authVersion: 1,
    voyageBaseUrl: Uri.parse('https://voyage.example.com'),
    sourceServerFingerprint: fingerprint,
    accessToken: 'access-token',
    accessTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    rejoinToken: 'rejoin-token',
  );
}

GroupListeningRoomState _roomState({
  required String fingerprint,
  required int roomVersion,
  required List<String> queueSongIds,
  required int? currentIndex,
  required GroupListeningPlaybackStatus playbackState,
  required Duration position,
  required String issuedByMemberId,
  String? issuedByConnectionId,
  GroupListeningMemberRole selfRole = GroupListeningMemberRole.host,
  bool selfCanControl = true,
}) {
  final timestamp = DateTime.utc(2026, 4, 21, 12, 0, roomVersion);
  final selfMemberId = selfRole == GroupListeningMemberRole.host
      ? 'member-1'
      : 'member-2';
  final entries = <GroupListeningQueueEntry>[
    for (var i = 0; i < queueSongIds.length; i++)
      GroupListeningQueueEntry(
        queueEntryId: 'entry-${roomVersion + i}',
        songId: queueSongIds[i],
        addedByMemberId: issuedByMemberId,
        addedAt: timestamp,
      ),
  ];
  final currentQueueEntryId =
      currentIndex != null && currentIndex >= 0 && currentIndex < entries.length
      ? entries[currentIndex].queueEntryId
      : null;
  final currentSongId =
      currentIndex != null &&
          currentIndex >= 0 &&
          currentIndex < queueSongIds.length
      ? queueSongIds[currentIndex]
      : null;
  return GroupListeningRoomState(
    protocolVersion: voyageProtocolVersion,
    roomId: 'room-1',
    roomStatus: GroupListeningRoomStatus.active,
    roomVersion: roomVersion,
    presenceVersion: 1,
    authVersion: 1,
    serverTime: timestamp,
    sourceServerFingerprint: fingerprint,
    hostMemberId: 'member-1',
    self: GroupListeningSelfState(
      memberId: selfMemberId,
      role: selfRole,
      canControl: selfCanControl,
      authVersion: 1,
    ),
    members: <GroupListeningMemberState>[
      GroupListeningMemberState(
        memberId: 'member-1',
        displayName: 'Alice',
        deviceLabel: 'Desktop',
        role: GroupListeningMemberRole.host,
        presenceState: GroupListeningMemberPresenceState.active,
        capabilities: const <String>{'playback_anchor'},
        joinedAt: timestamp,
        lastSeenAt: timestamp,
      ),
      GroupListeningMemberState(
        memberId: 'member-2',
        displayName: 'Bob',
        deviceLabel: 'Phone',
        role: GroupListeningMemberRole.member,
        presenceState: GroupListeningMemberPresenceState.active,
        capabilities: const <String>{'playback_anchor'},
        joinedAt: timestamp,
        lastSeenAt: timestamp,
      ),
    ],
    queue: GroupListeningQueueState(
      queueVersion: roomVersion,
      currentIndex: currentIndex,
      entries: entries,
    ),
    playbackAnchor: GroupListeningPlaybackAnchor(
      roomVersion: roomVersion,
      queueVersion: roomVersion,
      currentIndex: currentIndex,
      currentQueueEntryId: currentQueueEntryId,
      currentSongId: currentSongId,
      playbackState: playbackState,
      position: position,
      capturedAt: timestamp,
      playbackRate: 1,
      reason: GroupListeningPlaybackAnchorReason.snapshot,
      issuedByMemberId: issuedByMemberId,
      issuedByConnectionId: issuedByConnectionId,
    ),
  );
}

GroupListeningRoomEvent _roomEvent({
  required int roomVersion,
  required int previousRoomVersion,
  required List<String> queueSongIds,
  required int? currentIndex,
  required GroupListeningPlaybackStatus playbackState,
  required Duration position,
  required String issuedByMemberId,
  String? issuedByConnectionId,
  bool includePlaybackAnchor = true,
  GroupListeningRoomEventType? eventType,
}) {
  final timestamp = DateTime.utc(2026, 4, 21, 12, 0, roomVersion);
  final entries = <GroupListeningQueueEntry>[
    for (var i = 0; i < queueSongIds.length; i++)
      GroupListeningQueueEntry(
        queueEntryId: 'entry-${roomVersion + i}',
        songId: queueSongIds[i],
        addedByMemberId: issuedByMemberId,
        addedAt: timestamp,
      ),
  ];
  final currentQueueEntryId =
      currentIndex != null && currentIndex >= 0 && currentIndex < entries.length
      ? entries[currentIndex].queueEntryId
      : null;
  final currentSongId =
      currentIndex != null &&
          currentIndex >= 0 &&
          currentIndex < queueSongIds.length
      ? queueSongIds[currentIndex]
      : null;
  return GroupListeningRoomEvent(
    eventId: 'event-$roomVersion',
    eventType:
        eventType ??
        (queueSongIds.length == 1
            ? GroupListeningRoomEventType.seek
            : GroupListeningRoomEventType.queueReplace),
    roomId: 'room-1',
    previousRoomVersion: previousRoomVersion,
    roomVersion: roomVersion,
    causedByMemberId: issuedByMemberId,
    playbackAnchor: includePlaybackAnchor
        ? GroupListeningPlaybackAnchor(
            roomVersion: roomVersion,
            queueVersion: roomVersion,
            currentIndex: currentIndex,
            currentQueueEntryId: currentQueueEntryId,
            currentSongId: currentSongId,
            playbackState: playbackState,
            position: position,
            capturedAt: timestamp,
            playbackRate: 1,
            reason: GroupListeningPlaybackAnchorReason.trackChange,
            issuedByMemberId: issuedByMemberId,
            issuedByConnectionId: issuedByConnectionId,
          )
        : null,
    queue: GroupListeningQueueState(
      queueVersion: roomVersion,
      currentIndex: currentIndex,
      entries: entries,
    ),
  );
}

PlaybackSnapshot _snapshotFromRoom(GroupListeningRoomState room) {
  final anchor = room.playbackAnchor;
  return PlaybackSnapshot(
    queueSongIds: List<String>.unmodifiable(
      room.queue.entries.map((entry) => entry.songId),
    ),
    currentSongId: anchor!.currentSongId,
    currentIndex: anchor.currentIndex,
    playing: anchor.playbackState == GroupListeningPlaybackStatus.playing,
    processingState: AudioProcessingState.ready,
    position: anchor.position,
    duration: Duration.zero,
    bufferedPosition: Duration.zero,
    shuffleMode: AudioServiceShuffleMode.none,
    repeatMode: AudioServiceRepeatMode.none,
  );
}
