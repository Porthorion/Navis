import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/toggle_song_star.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _Feedback extends Mock implements ListenBrainzFeedbackService {}

void main() {
  late NavisDatabase database;
  late WidgetRef ref;

  setUp(() async {
    database = createTestDatabase();
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(id: 'lib-1', title: 'So it goes'),
      SongsTableCompanion.insert(id: 'ext-deezer-song-9', title: 'So It Goes'),
    ]);
  });

  tearDown(() => database.close());

  Future<void> pump(WidgetTester tester) async {
    final feedback = _Feedback();
    when(() => feedback.enqueueSongFeedback(any(), liked: any(named: 'liked')))
        .thenAnswer((_) async {});
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            audioHandlerProvider.overrideWithValue(null),
            listenBrainzFeedbackServiceProvider.overrideWithValue(feedback),
          ],
        ),
        child: Consumer(
          builder: (_, r, _) {
            ref = r;
            return const SizedBox();
          },
        ),
      ),
    );
  }

  testWidgets('a remote copy is refused without a star or a feedback event', (
    tester,
  ) async {
    await pump(tester);

    final applied = (await tester.runAsync(
      () => toggleSongStar('ext-deezer-song-9', ref),
    ))!;

    expect(applied, isFalse);
    expect(
      await tester.runAsync(
        () => database.libraryDao.getSongStarred('ext-deezer-song-9'),
      ),
      isNull,
    );
    expect(
      await tester.runAsync(() => database.starSyncDao.getPendingActions()),
      isEmpty,
    );
  }, skip: !sqliteAvailable);

  testWidgets('a library song is liked', (tester) async {
    await pump(tester);

    final applied = (await tester.runAsync(
      () => toggleSongStar('lib-1', ref),
    ))!;

    expect(applied, isTrue);
    expect(
      await tester.runAsync(() => database.libraryDao.getSongStarred('lib-1')),
      isNotNull,
    );
  }, skip: !sqliteAvailable);
}
