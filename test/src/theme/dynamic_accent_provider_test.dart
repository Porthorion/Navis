import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';

class _SongIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void next() => state++;
}

final _songIndexProvider = NotifierProvider<_SongIndexNotifier, int>(
  _SongIndexNotifier.new,
);

void main() {
  testWidgets('palette decode errors fall back without escaping', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final scheme = await artworkColorScheme(
        provider: MemoryImage(Uint8List.fromList([0, 1, 2])),
        brightness: Brightness.light,
      );
      expect(scheme, isNull);
    });
    expect(tester.takeException(), isNull);
  });
  group('effectiveColorSchemeSeedProvider', () {
    test('falls back to selected seed when dynamic seed is null', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          colorSchemeSeedProvider.overrideWith((_) => 0xFF123456),
          dynamicAccentSeedColorProvider.overrideWith((_) async => null),
        ],
      );
      addTearDown(container.dispose);

      await container.read(dynamicAccentSeedColorProvider.future);
      final effective = container.read(effectiveColorSchemeSeedProvider);

      expect(effective, 0xFF123456);
    });

    test('uses dynamic seed when available', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          colorSchemeSeedProvider.overrideWith((_) => 0xFF123456),
          dynamicAccentSeedColorProvider.overrideWith((_) async => 0xFFABCDEF),
        ],
      );
      addTearDown(container.dispose);

      await container.read(dynamicAccentSeedColorProvider.future);
      final effective = container.read(effectiveColorSchemeSeedProvider);

      expect(effective, 0xFFABCDEF);
    });

    group('while the next dynamic seed loads', () {
      ProviderContainer makeContainer(Map<int, Completer<int?>> seeds) {
        return ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            colorSchemeSeedProvider.overrideWith((_) => 0xFF123456),
            dynamicAccentSeedColorProvider.overrideWith((ref) {
              return seeds[ref.watch(_songIndexProvider)]!.future;
            }),
          ],
        );
      }

      Future<ProviderContainer> resolvedTo(
        Map<int, Completer<int?>> seeds,
        int? seed,
      ) async {
        final container = makeContainer(seeds);
        addTearDown(container.dispose);
        final subscription = container.listen(
          effectiveColorSchemeSeedProvider,
          (_, _) {},
        );
        addTearDown(subscription.close);

        final first = container.read(dynamicAccentSeedColorProvider.future);
        seeds[0]!.complete(seed);
        await first;
        return container;
      }

      test('keeps the previous dynamic seed', () async {
        final seeds = {0: Completer<int?>(), 1: Completer<int?>()};
        final container = await resolvedTo(seeds, 0xFFABCDEF);
        expect(container.read(effectiveColorSchemeSeedProvider), 0xFFABCDEF);

        container.read(_songIndexProvider.notifier).next();
        expect(
          container.read(dynamicAccentSeedColorProvider).isLoading,
          isTrue,
        );
        expect(container.read(effectiveColorSchemeSeedProvider), 0xFFABCDEF);

        final second = container.read(dynamicAccentSeedColorProvider.future);
        seeds[1]!.complete(0xFF00FF00);
        await second;
        expect(container.read(effectiveColorSchemeSeedProvider), 0xFF00FF00);
      });

      test(
        'falls back to the selected seed when the previous was null',
        () async {
          final seeds = {0: Completer<int?>(), 1: Completer<int?>()};
          final container = await resolvedTo(seeds, null);
          expect(container.read(effectiveColorSchemeSeedProvider), 0xFF123456);

          container.read(_songIndexProvider.notifier).next();
          expect(
            container.read(dynamicAccentSeedColorProvider).isLoading,
            isTrue,
          );
          expect(container.read(effectiveColorSchemeSeedProvider), 0xFF123456);
        },
      );

      test(
        'falls back to the selected seed when the next one is null',
        () async {
          final seeds = {0: Completer<int?>(), 1: Completer<int?>()};
          final container = await resolvedTo(seeds, 0xFFABCDEF);

          container.read(_songIndexProvider.notifier).next();
          final second = container.read(dynamicAccentSeedColorProvider.future);
          seeds[1]!.complete(null);
          await second;
          expect(container.read(effectiveColorSchemeSeedProvider), 0xFF123456);
        },
      );
    });
  });
}
