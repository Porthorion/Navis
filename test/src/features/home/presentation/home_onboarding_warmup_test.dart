import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/home/domain/home_section_ids.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/home_onboarding_warmup.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _LikedOnlyHomeFilterController extends HomeLikedOnlyFilterController {
  @override
  bool build() => true;
}

final _mobileHomeWarmupResolverProvider =
    FutureProvider<List<HomeArtworkWarmupTarget>>(
      (ref) => resolveHomeOnboardingWarmupTargets(ref, desktopRuntime: false),
    );

void main() {
  HomeArtworkWarmupTarget target(String id, int size) {
    return HomeArtworkWarmupTarget(coverArtId: id, size: size);
  }

  group('selectHomeArtworkWarmupTargets', () {
    test('honors visible Home order, deduplicates IDs, and caps at six', () {
      final selected = selectHomeArtworkWarmupTargets(
        sectionOrder: const <String>[
          'recentlyAdded',
          'hidden',
          'likedTracks',
          'unsupportedDiscovery',
        ],
        hiddenSections: const <String>{'hidden'},
        targetsBySection: <String, List<HomeArtworkWarmupTarget>>{
          'recentlyAdded': <HomeArtworkWarmupTarget>[
            target('newest', 600),
            target('shared', 600),
            target('  ', 600),
          ],
          'hidden': <HomeArtworkWarmupTarget>[target('hidden-cover', 600)],
          'likedTracks': <HomeArtworkWarmupTarget>[
            target('shared', 160),
            target('liked-one', 160),
            target('liked-two', 160),
            target('liked-three', 160),
            target('liked-four', 160),
            target('liked-five', 160),
          ],
          // External discovery does not provide a supported Home target and
          // is deliberately absent from the visible section data.
          'unsupportedDiscovery': const <HomeArtworkWarmupTarget>[],
        },
      );

      expect(selected.map((candidate) => candidate.coverArtId), <String>[
        'newest',
        'shared',
        'liked-one',
        'liked-two',
        'liked-three',
        'liked-four',
      ]);
      expect(selected[0].size, 600);
      expect(
        selected.skip(2).every((candidate) => candidate.size == 160),
        isTrue,
      );
    });

    test(
      'keeps the first visible surface image variant for a shared cover',
      () {
        final selected = selectHomeArtworkWarmupTargets(
          sectionOrder: const <String>['featuredHero', 'likedTracks'],
          hiddenSections: const <String>{},
          targetsBySection: <String, List<HomeArtworkWarmupTarget>>{
            'featuredHero': <HomeArtworkWarmupTarget>[target('shared', 600)],
            'likedTracks': <HomeArtworkWarmupTarget>[target('shared', 160)],
          },
        );

        expect(selected, hasLength(1));
        expect(selected.single.coverArtId, 'shared');
        expect(selected.single.size, 600);
      },
    );

    test(
      'uses the filtered Home provider and excludes external discovery',
      () async {
        final container = ProviderContainer(
          overrides: [
            homeSectionOrderProvider.overrideWithValue(const <String>[
              HomeSectionIds.randomAlbums,
            ]),
            // Every other section is hidden; a saved order gains the
            // default sections it lacks.
            homeSectionsHiddenProvider.overrideWithValue(<String>[
              for (final id in HomeSectionIds.defaultOrder)
                if (id != HomeSectionIds.randomAlbums) id,
            ]),
            homeLikedOnlyFilterProvider.overrideWith(
              _LikedOnlyHomeFilterController.new,
            ),
            homeRandomAlbumsProvider.overrideWithValue(
              AsyncData(<Album>[
                const Album(
                  id: 'not-liked',
                  name: 'Not liked',
                  coverArt: 'not-liked-cover',
                ),
                Album(
                  id: 'liked',
                  name: 'Liked',
                  coverArt: 'liked-cover',
                  starred: DateTime.utc(2026, 8, 26),
                ),
                const Album(
                  id: 'external',
                  name: 'External',
                  coverArt: 'external-cover',
                  isExternal: true,
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        final selected = await container.read(
          _mobileHomeWarmupResolverProvider.future,
        );

        expect(selected, hasLength(1));
        expect(selected.single.coverArtId, 'liked-cover');
        expect(selected.single.size, 600);
      },
    );
  });

  test('warms nothing for New releases and never asks Deezer', () async {
    var newReleasesBuilt = false;
    final container = ProviderContainer(
      overrides: [
        homeSectionOrderProvider.overrideWithValue(null),
        homeSectionsHiddenProvider.overrideWithValue(<String>[
          for (final id in HomeSectionIds.defaultOrder)
            if (id != HomeSectionIds.newReleases) id,
        ]),
        homeNewReleasesProvider.overrideWith((ref) {
          newReleasesBuilt = true;
          return const <HomeNewRelease>[];
        }),
        deezerApiClientProvider.overrideWith(
          (ref) => throw StateError('the warmup asked Deezer'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final selected = await container.read(
      _mobileHomeWarmupResolverProvider.future,
    );

    expect(selected, isEmpty);
    expect(newReleasesBuilt, isFalse);
  });

  group('HomeOnboardingWarmup', () {
    test(
      'runs one background artwork request at a time and decodes three',
      () async {
        final firstStarted = Completer<void>();
        final firstCanFinish = Completer<void>();
        final started = <String>[];
        final decoded = <String>[];
        final warmup = HomeOnboardingWarmup(
          resolveTargets: () async => <HomeArtworkWarmupTarget>[
            target('one', 600),
            target('two', 600),
            target('three', 160),
            target('four', 160),
          ],
          warmTarget: (candidate) async {
            started.add(candidate.coverArtId);
            if (candidate.coverArtId == 'one') {
              firstStarted.complete();
              await firstCanFinish.future;
            }
          },
          isOnline: () => true,
        );

        final session = warmup.start(
          onArtworkReady: (candidate) async =>
              decoded.add(candidate.coverArtId),
        );
        await firstStarted.future;

        // Starting is non-blocking and the next request is not scheduled until
        // the current low-priority request has completed.
        expect(started, <String>['one']);
        firstCanFinish.complete();
        await session.done;

        expect(started, <String>['one', 'two', 'three', 'four']);
        expect(decoded, <String>['one', 'two', 'three']);
      },
    );

    test('does not schedule more artwork after onboarding exits', () async {
      final firstStarted = Completer<void>();
      final firstCanFinish = Completer<void>();
      final started = <String>[];
      final warmup = HomeOnboardingWarmup(
        resolveTargets: () async => <HomeArtworkWarmupTarget>[
          target('one', 600),
          target('two', 600),
        ],
        warmTarget: (candidate) async {
          started.add(candidate.coverArtId);
          if (candidate.coverArtId == 'one') {
            firstStarted.complete();
            await firstCanFinish.future;
          }
        },
        isOnline: () => true,
      );

      final session = warmup.start();
      await firstStarted.future;
      session.stop();
      firstCanFinish.complete();
      await session.done;

      expect(started, <String>['one']);
    });

    test('skips all network work while offline', () async {
      var resolved = false;
      final warmup = HomeOnboardingWarmup(
        resolveTargets: () async {
          resolved = true;
          return <HomeArtworkWarmupTarget>[target('one', 600)];
        },
        warmTarget: (_) async {},
        isOnline: () => false,
      );

      await warmup.start().done;

      expect(resolved, isFalse);
    });

    testWidgets(
      'starts after onboarding paints and stops when the app backgrounds',
      (tester) async {
        final targetsReady = Completer<List<HomeArtworkWarmupTarget>>();
        var resolverCalls = 0;
        var warmed = 0;
        final warmup = HomeOnboardingWarmup(
          resolveTargets: () {
            resolverCalls += 1;
            return targetsReady.future;
          },
          warmTarget: (_) async => warmed += 1,
          isOnline: () => true,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              onboardingRequiredProvider.overrideWithValue(true),
              appSettingsProvider.overrideWithValue(
                const AsyncData(AppSettingsModel.defaults()),
              ),
              customColorPresetsProvider.overrideWithValue(
                const AsyncData(<int>[]),
              ),
              homeOnboardingWarmupProvider.overrideWithValue(warmup),
            ],
            child: const MaterialApp(
              localizationsDelegates: navisLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: OnboardingScreen(homeWarmupAfterRebuild: true),
            ),
          ),
        );

        // The first rendered frame remains the normal, interactive setup UI.
        expect(find.text('Make Navis Yours'), findsOneWidget);
        await tester.pump();
        expect(resolverCalls, 1);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        targetsReady.complete(<HomeArtworkWarmupTarget>[target('one', 600)]);
        await tester.pump();
        await tester.pump();

        expect(warmed, 0);
      },
    );
  });
}
