import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/presentation/genre_providers.dart';
import 'package:navis/src/features/player/presentation/replay_gain_untagged_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _Epoch extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final _epochProvider = NotifierProvider<_Epoch, int>(_Epoch.new);

void main() {
  late NavisDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = createTestDatabase();
    container = ProviderContainer(
      overrides: [
        navisDatabaseProvider.overrideWithValue(db),
        genreDataEpochProvider.overrideWith((ref) => ref.watch(_epochProvider)),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> tag(int from, int to, double gain) async {
    await db.batch(
      (batch) => batch.insertAll(db.songsTable, [
        for (var i = from; i < to; i++)
          SongsTableCompanion.insert(
            id: 's$i',
            title: 'Song $i',
            replayGainTrackGain: Value(gain),
          ),
      ]),
    );
  }

  test('with fewer than 20 tagged songs the level is -8 dB', () async {
    await tag(0, 19, -10);
    expect(await container.read(replayGainAutoUntaggedDbProvider.future), -8);
  });

  test('with 20 tagged songs the level is their median', () async {
    await tag(0, 20, -10);
    await tag(20, 25, 918);
    expect(await container.read(replayGainAutoUntaggedDbProvider.future), -10);
  });

  test('recomputes after a library sync', () async {
    await tag(0, 20, -10);
    final subscription = container.listen(
      replayGainAutoUntaggedDbProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    expect(await container.read(replayGainAutoUntaggedDbProvider.future), -10);
    await tag(20, 80, -14);
    container.read(_epochProvider.notifier).bump();
    expect(await container.read(replayGainAutoUntaggedDbProvider.future), -14);
  });

  group('effectiveReplayGainUntaggedDb', () {
    test('a fixed level wins over the library level', () {
      expect(
        effectiveReplayGainUntaggedDb(
          fixed: -5,
          auto: const AsyncData<double>(-9),
        ),
        -5,
      );
    });

    test('Automatic uses the library level', () {
      expect(
        effectiveReplayGainUntaggedDb(
          fixed: null,
          auto: const AsyncData<double>(-9),
        ),
        -9,
      );
    });

    test('a reload keeps the previous library level', () async {
      await tag(0, 20, -10);
      final subscription = container.listen(
        replayGainAutoUntaggedDbProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container.read(replayGainAutoUntaggedDbProvider.future);
      container.read(_epochProvider.notifier).bump();
      final reloading = container.read(replayGainAutoUntaggedDbProvider);
      expect(reloading.isLoading, isTrue);
      expect(effectiveReplayGainUntaggedDb(fixed: null, auto: reloading), -10);
    });

    test('before the first library level it is -8 dB', () {
      expect(
        effectiveReplayGainUntaggedDb(
          fixed: null,
          auto: const AsyncLoading<double>(),
        ),
        -8,
      );
    });
  });
}
