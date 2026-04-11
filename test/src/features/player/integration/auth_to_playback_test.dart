import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import '../../../../helpers/test_database.dart';

class _RecordingPlaybackHandler implements NavisPlaybackHandler {
  int replaceQueueCalls = 0;
  int playCalls = 0;
  List<String> lastQueue = const <String>[];

  @override
  PlaybackSnapshot get snapshot => const PlaybackSnapshot.idle();

  @override
  Stream<PlaybackSnapshot> get snapshotStream =>
      const Stream<PlaybackSnapshot>.empty();

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  MediaItem? get currentMediaItem => null;

  @override
  Stream<MediaItem?> get mediaItemStream => const Stream<MediaItem?>.empty();

  @override
  Stream<void> get radioStreamErrorStream => const Stream<void>.empty();

  @override
  Stream<ManualTrackChangeCue> get manualTrackChangeCueStream =>
      const Stream<ManualTrackChangeCue>.empty();

  @override
  Future<void> waitUntilReady() async {}

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
  }) async {
    replaceQueueCalls += 1;
    lastQueue = List<String>.from(songIds);
  }

  @override
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
  }) async {
    replaceQueueCalls += 1;
    lastQueue = songs.map((s) => s.id).toList();
  }

  @override
  Future<void> play() async {
    playCalls += 1;
  }

  @override
  Future<void> addToQueue(List<String> songIds) async {}

  @override
  Future<void> applyRuntimeSettings() async {}

  @override
  Future<void> clearQueue() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playFromIndex(int index) async {}

  @override
  Future<void> playNext(List<String> songIds) async {}

  @override
  Future<void> removeAt(int index) async {}

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(double speed) async {}

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {}

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> stopRadio() async {}

  @override
  Future<void> syncSongLikedState(String songId, {required bool liked}) async {}

  @override
  Future<void> toggleLike() async {}

  @override
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  }) async {}

  @override
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
  }) {}

  @override
  void registerPreferredMixCallback(Future<void> Function(String seedSongId) callback) {}
  @override
  void registerPreferredMixToggleCallback(Future<void> Function(String seedSongId) callback) {}
  @override
  void registerMixActiveReader(bool Function() reader) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'authenticated context can persist remote song fixture and trigger playback queue',
    () async {
      final db = createTestDatabase();
      addTearDown(db.close);

      final handler = _RecordingPlaybackHandler();
      final container = ProviderContainer(
        overrides: [
          ...withTestDatabase(db),
          networkTypeProvider.overrideWith((_) => NetworkType.wifi),
          audioHandlerProvider.overrideWithValue(handler),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final api = container.read(subsonicApiProvider);
      expect(api, isNotNull);

      final fixtureSong = Song(
        id: 'remote-song-1',
        title: 'Fixture Song',
        album: 'Fixture Album',
        albumId: 'fixture-album-1',
        artist: 'Fixture Artist',
        artistId: 'fixture-artist-1',
        track: 1,
        duration: 180,
        coverArt: 'cover-1',
        bitRate: 320,
        suffix: 'mp3',
        contentType: 'audio/mpeg',
        size: 1,
      );

      final queue = container.read(queueProvider.notifier);
      await queue.replaceWithSongs(<Song>[fixtureSong]);

      expect(handler.replaceQueueCalls, 1);
      expect(handler.playCalls, 1);
      expect(handler.lastQueue, <String>['remote-song-1']);

      final persisted = await db.libraryDao.getSongsByIds(
        const <String>['remote-song-1'],
      );
      expect(persisted, isNotEmpty);
      expect(persisted.first.title, 'Fixture Song');
    },
  );
}
