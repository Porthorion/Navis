import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';

import '../../../../helpers/test_database.dart';

class _FakeListenBrainzFeedbackApiClient extends ListenBrainzApiClient {
  new({this.lookupResult});

  final String? lookupResult;
  final submitted = <({String recordingMbid, int score})>[];
  int lookupCalls = 0;

  @override
  Future<String?> lookupRecordingMbid({
    required String userToken,
    required String title,
    required String artist,
    String? album,
  }) async {
    lookupCalls++;
    return lookupResult;
  }

  @override
  Future<void> submitRecordingFeedback({
    required String userToken,
    String? recordingMbid,
    String? recordingMsid,
    required int score,
  }) async {
    submitted.add((recordingMbid: recordingMbid!, score: score));
  }
}

Future<void> _insertSong(
  NavisDatabase database, {
  required String id,
  String? recordingMbid,
}) {
  return database
      .into(database.songsTable)
      .insert(
        SongsTableCompanion.insert(
          id: id,
          title: 'Song $id',
          artistName: const Value('Artist'),
          albumName: const Value('Album'),
          recordingMbid: Value(recordingMbid),
        ),
      );
}

void main() {
  test('like and unlike queue latest score and submit cached MBID', () async {
    final database = createTestDatabase();
    final client = _FakeListenBrainzFeedbackApiClient();
    addTearDown(database.close);
    await _insertSong(
      database,
      id: 'song-1',
      recordingMbid: '22222222-2222-2222-2222-222222222222',
    );
    var reachable = false;
    final service = ListenBrainzFeedbackService(
      dao: database.listenBrainzFeedbackDao,
      libraryDao: database.libraryDao,
      readCredentials: () async =>
          const ListenBrainzFeedbackCredentials(userToken: 'token'),
      createClient: () => client,
      readReachable: () => reachable,
    );

    await service.enqueueSongFeedback('song-1', liked: true);
    await service.enqueueSongFeedback('song-1', liked: false);
    reachable = true;
    await service.flush();

    expect(client.lookupCalls, 0);
    expect(client.submitted, hasLength(1));
    expect(client.submitted.single.score, 0);
    expect(
      client.submitted.single.recordingMbid,
      '22222222-2222-2222-2222-222222222222',
    );
    expect(
      await database.listenBrainzFeedbackDao.getDueFeedback(
        now: DateTime.now(),
      ),
      isEmpty,
    );
  });

  test('missing cached MBID looks up, caches, and submits feedback', () async {
    final database = createTestDatabase();
    final client = _FakeListenBrainzFeedbackApiClient(
      lookupResult: '33333333-3333-3333-3333-333333333333',
    );
    addTearDown(database.close);
    await _insertSong(database, id: 'song-2');
    var reachable = false;
    final service = ListenBrainzFeedbackService(
      dao: database.listenBrainzFeedbackDao,
      libraryDao: database.libraryDao,
      readCredentials: () async =>
          const ListenBrainzFeedbackCredentials(userToken: 'token'),
      createClient: () => client,
      readReachable: () => reachable,
    );

    await service.enqueueSongFeedback('song-2', liked: true);
    reachable = true;
    await service.flush();

    expect(client.lookupCalls, 1);
    expect(client.submitted.single.score, 1);
    expect(
      client.submitted.single.recordingMbid,
      '33333333-3333-3333-3333-333333333333',
    );
    final song = await database.libraryDao.getSongById('song-2');
    expect(song?.recordingMbid, '33333333-3333-3333-3333-333333333333');
  });

  test('missing lookup result drops queued feedback', () async {
    final database = createTestDatabase();
    final client = _FakeListenBrainzFeedbackApiClient();
    addTearDown(database.close);
    await _insertSong(database, id: 'song-3');
    var reachable = false;
    final service = ListenBrainzFeedbackService(
      dao: database.listenBrainzFeedbackDao,
      libraryDao: database.libraryDao,
      readCredentials: () async =>
          const ListenBrainzFeedbackCredentials(userToken: 'token'),
      createClient: () => client,
      readReachable: () => reachable,
    );

    await service.enqueueSongFeedback('song-3', liked: true);
    reachable = true;
    await service.flush();

    expect(client.lookupCalls, 1);
    expect(client.submitted, isEmpty);
    expect(
      await database.listenBrainzFeedbackDao.getDueFeedback(
        now: DateTime.now(),
      ),
      isEmpty,
    );
  });

  group('readListenBrainzFeedbackCredentials policy gate', () {
    const verified = IntegrationPolicy(listenBrainzVerified: true);

    test('returns the trimmed token while allowed', () async {
      final credentials = await readListenBrainzFeedbackCredentials(
        policy: verified,
        readToken: () async => '  secret-token  ',
      );
      expect(credentials?.userToken, 'secret-token');
    });

    for (final entry in <String, IntegrationPolicy>{
      'the feature switch is off': const IntegrationPolicy(
        listenBrainzVerified: true,
        disabledKeys: {'listenbrainz.feedback'},
      ),
      'the ListenBrainz service is off': const IntegrationPolicy(
        listenBrainzVerified: true,
        disabledKeys: {'listenbrainz'},
      ),
      'the master switch is off': const IntegrationPolicy(
        listenBrainzVerified: true,
        masterEnabled: false,
      ),
      'the token is not validated': const IntegrationPolicy(),
    }.entries) {
      test('never reads the token when ${entry.key}', () async {
        var tokenReads = 0;
        final credentials = await readListenBrainzFeedbackCredentials(
          policy: entry.value,
          readToken: () async {
            tokenReads++;
            return 'secret-token';
          },
        );
        expect(credentials, isNull);
        expect(tokenReads, 0);
      });
    }

    test('returns null without a stored token', () async {
      expect(
        await readListenBrainzFeedbackCredentials(
          policy: verified,
          readToken: () async => '  ',
        ),
        isNull,
      );
      expect(
        await readListenBrainzFeedbackCredentials(
          policy: verified,
          readToken: () async => null,
        ),
        isNull,
      );
    });
  });
}
