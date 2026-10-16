import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/home/domain/home_section_ids.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_corner_style.dart';

import '../../../../helpers/test_database.dart';

void main() {
  group('SettingsRepository', () {
    late NavisDatabase database;
    late SettingsRepository repository;

    setUp(() {
      database = createTestDatabase();
      repository = SettingsRepository(database.appSettingsDao);
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'stale generic save preserves appearance, Looks and Home sections',
      () async {
        final stale = await repository.getSettings();
        final dao = database.appSettingsDao;
        final snapshot = AppearanceSnapshot.capture(
          stale.copyWith(
            themeMode: 'light',
            oledForAuto: true,
            colorStyle: 'immersive',
            colorSchemeSeed: 0xFF123456,
            dynamicAlbumColorEnabled: true,
            nightScheduleEnabled: true,
            nightScheduleStartMinutes: 100,
            nightScheduleEndMinutes: 200,
            albumArtShade: true,
            albumArtColoredShade: true,
            colorVividness: 2,
            surfaceDepthLight: 3,
            surfaceDepthDark: -3,
            surfaceTintLight: 2,
            surfaceTintDark: 3,
            controlColor: 'white',
            flatSurfaces: true,
            flatAreas: FlatAreas.fromBits(2),
            cornerStyle: NavisCornerStyle.square,
            nowPlayingBackground: NowPlayingBackground.artwork,
          ),
        );
        await dao.applyAppearanceSnapshot(snapshot);
        await dao.updateDensity(NavisDensity.compact);
        await dao.updateArtistViewMode('list');
        await dao.updateGridArtworkSize('large');
        await dao.updateCoverArtShape('rounded');
        await dao.updateNowPlayingArtShape('circle');
        await dao.updateArtistCardShape('square');
        await database.customStatement(
          'UPDATE app_settings SET album_grid_density = 6',
        );
        final look = AppearanceLook(id: 'new', name: 'New', snapshot: snapshot);
        await dao.updateAppearanceLooks(
          selectedLookId: look.id,
          looksJson: jsonEncode([look.toJson()]),
        );
        await dao.updateHomeSectionsHidden('["recently_added"]');
        await dao.updateHomeSectionOrder(
          '["recently_added","recently_played"]',
        );
        final before = (await dao.getSettings())!.toJson()..remove('updatedAt');

        await repository.saveSettings(stale.copyWith(scrobbleEnabled: false));

        final saved = await repository.getSettings();
        expect(saved.themeMode, 'light');
        expect(saved.selectedAppearanceLookId, look.id);
        expect(saved.appearanceLooks.single.snapshot, snapshot);
        expect(saved.homeSectionsHidden, ['recently_added']);
        expect(saved.scrobbleEnabled, isFalse);
        final after = (await dao.getSettings())!.toJson()..remove('updatedAt');
        expect(after, {...before, 'scrobbleEnabled': false});
      },
      skip: !sqliteAvailable,
    );

    test(
      'hidden Home sections distinguish built-in defaults from none',
      () async {
        final dao = database.appSettingsDao;
        await dao.updateHomeSectionOrder(
          jsonEncode(HomeSectionIds.defaultOrder),
        );
        await dao.updateHomeSectionsHidden(null);
        expect(
          HomeSectionIds.resolveHidden(
            (await repository.getSettings()).homeSectionsHidden,
          ),
          HomeSectionIds.defaultHidden,
        );
        await dao.updateHomeSectionsHidden('[]');
        final saved = await repository.getSettings();
        expect(saved.homeSectionsHidden, isEmpty);
        expect(
          HomeSectionIds.resolveHidden(
            saved.homeSectionsHidden,
            persistedOrder: saved.homeSectionOrder,
          ),
          isEmpty,
        );
      },
      skip: !sqliteAvailable,
    );

    test('nothing hidden on Home survives a full save', () async {
      final initial = await repository.getSettings();
      expect(initial.homeSectionsHidden, isNull);
      await database.appSettingsDao.updateHomeSectionsHidden('[]');
      final none = await repository.getSettings();
      expect(none.homeSectionsHidden, isEmpty);
      await repository.saveSettings(none);
      expect((await repository.getSettings()).homeSectionsHidden, isEmpty);
    });

    test(
      'setup preserves concurrent tint and controls unless changed in draft',
      () async {
        final initial = await repository.getSettings();
        final draft = initial.copyWith(
          surfaceTintLight: 3,
          controlColor: 'white',
        );
        await database.appSettingsDao.updateColorTuning(draft.colorTuning);
        expect(
          (await repository.watchSettings().first).colorTuning,
          const ColorTuning(lightTint: 3, controls: NavisControlColor.white),
        );
        await database.appSettingsDao.updateColorTuning(
          const ColorTuning(
            lightTint: 5,
            darkTint: 4,
            controls: NavisControlColor.white,
          ),
        );
        await repository.saveOnboardingChanges(
          draft,
          draft.copyWith(surfaceDepthDark: 2),
        );
        expect(
          (await repository.getSettings()).colorTuning,
          const ColorTuning(
            darkDepth: 2,
            lightTint: 5,
            darkTint: 4,
            controls: NavisControlColor.white,
          ),
        );
        await repository.saveOnboardingChanges(
          draft,
          draft.copyWith(surfaceTintLight: 1, controlColor: 'accent'),
        );
        expect(
          (await repository.getSettings()).colorTuning,
          const ColorTuning(darkDepth: 2, lightTint: 1, darkTint: 4),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'color tuning round trips and setup preserves concurrent unchanged axes',
      () async {
        final initial = await repository.getSettings();
        expect(initial.colorVividness, 0);
        expect(initial.surfaceDepthLight, 0);
        final draft = initial.copyWith(
          colorVividness: -3,
          surfaceDepthLight: 4,
        );
        await database.appSettingsDao.updateColorTuning(draft.colorTuning);
        final saved = await repository.getSettings();
        final watched = await repository.watchSettings().first;
        expect(saved.colorVividness, -3);
        expect(saved.surfaceDepthLight, 4);
        expect(watched.colorVividness, -3);
        expect(watched.surfaceDepthLight, 4);
        await database.appSettingsDao.updateColorTuning(
          const ColorTuning(vividness: 2, lightDepth: -5, darkDepth: 3),
        );
        await repository.saveOnboardingChanges(
          saved,
          saved.copyWith(colorVividness: 5),
        );
        final setup = await repository.getSettings();
        expect(setup.colorVividness, 5);
        expect(setup.surfaceDepthLight, -5);
        expect(setup.surfaceDepthDark, 3);
        await repository.saveOnboardingChanges(
          saved,
          saved.copyWith(themeMode: 'light'),
        );
        expect((await repository.getSettings()).colorVividness, 5);
        expect((await repository.getSettings()).surfaceDepthLight, -5);
        await repository.saveOnboardingChanges(
          saved,
          saved.copyWith(surfaceDepthDark: -4),
        );
        final darkEdited = await repository.getSettings();
        expect(
          darkEdited.colorTuning,
          const ColorTuning(vividness: 5, lightDepth: -5, darkDepth: -4),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'setup Finish preserves values changed elsewhere after entry',
      () async {
        final initial = await repository.getSettings();
        await repository.saveDesktopPlaybackVolume(
          volume: 0.3,
          lastAudibleVolume: 0.3,
        );
        await database.appSettingsDao.updateColorStyle('immersive');
        await database.appSettingsDao.updateNightSchedule(startMinutes: 1000);
        final draft = initial.copyWith(
          themeMode: 'oled',
          nightScheduleEnabled: true,
          wifiMaxBitRate: 128,
          clearWifiFormat: true,
          albumQueueEnabled: false,
        );
        await repository.saveOnboardingChanges(initial, draft);
        final saved = await repository.getSettings();
        expect(saved.desktopPlaybackVolume, 0.3);
        expect(saved.colorStyle, 'immersive');
        expect(saved.nightScheduleStartMinutes, 1000);
        expect(saved.nightScheduleEnabled, isTrue);
        expect(saved.themeMode, 'oled');
        expect(saved.wifiMaxBitRate, 128);
        expect(saved.wifiFormat, isNull);
        expect(saved.albumQueueEnabled, isFalse);
      },
    );

    test(
      'shade flags round trip independently through save and watch',
      () async {
        final defaults = await repository.getSettings();
        expect(defaults.albumArtShade, isFalse);
        expect(const AppSettingsModel.defaults().albumArtShade, isFalse);
        for (final shade in [false, true]) {
          for (final colored in [false, true]) {
            final draft = defaults.copyWith(
              albumArtShade: shade,
              albumArtColoredShade: colored,
            );
            expect(draft.copyWith(themeMode: 'oled').albumArtShade, shade);
            await database.appSettingsDao.updateAlbumArtShade(enabled: shade);
            await database.appSettingsDao.updateAlbumArtColoredShade(
              enabled: colored,
            );
            final saved = await repository.getSettings();
            final watched = await repository.watchSettings().first;
            final row = (await database.appSettingsDao.getSettings())!;
            expect(saved.albumArtShade, shade);
            expect(saved.albumArtColoredShade, colored);
            expect(watched.albumArtShade, shade);
            expect(watched.albumArtColoredShade, colored);
            expect(row.albumArtShade, shade);
            expect(row.albumArtColoredShade, colored);
          }
        }
      },
      skip: !sqliteAvailable,
    );

    test('setup shade diff preserves concurrent flags until changed', () async {
      final initial = await repository.getSettings();
      await database.appSettingsDao.updateAlbumArtShade(enabled: true);
      await database.appSettingsDao.updateAlbumArtColoredShade(enabled: true);
      await repository.saveOnboardingChanges(
        initial,
        initial.copyWith(themeMode: 'oled'),
      );
      var saved = await repository.getSettings();
      expect(saved.albumArtShade, isTrue);
      expect(saved.albumArtColoredShade, isTrue);
      await repository.saveOnboardingChanges(
        saved,
        saved.copyWith(albumArtShade: false),
      );
      saved = await repository.getSettings();
      expect(saved.albumArtShade, isFalse);
      expect(saved.albumArtColoredShade, isTrue);
      await repository.saveOnboardingChanges(
        saved,
        saved.copyWith(albumArtShade: true, albumArtColoredShade: false),
      );
      saved = await repository.getSettings();
      expect(saved.albumArtShade, isTrue);
      expect(saved.albumArtColoredShade, isFalse);
    }, skip: !sqliteAvailable);

    test('Flat areas and shade round trip and reset independently', () async {
      final initial = await repository.getSettings();
      expect(initial.flatAreas.bits, 7);
      expect(initial.albumArtColoredShade, isFalse);
      for (var bits = 0; bits <= 7; bits++) {
        final areas = FlatAreas.fromBits(bits);
        await database.appSettingsDao.updateFlatAreas(areas.bits);
        await database.appSettingsDao.updateAlbumArtColoredShade(enabled: true);
        final saved = await repository.getSettings();
        expect(saved.flatAreas, areas);
        expect(saved.albumArtColoredShade, isTrue);
        expect((await repository.watchSettings().first).flatAreas, areas);
        expect((await database.appSettingsDao.getSettings())!.flatAreas, bits);
      }
    }, skip: !sqliteAvailable);

    test(
      'setup diffs preserve concurrent area/shade writes until changed',
      () async {
        final initial = await repository.getSettings();
        await database.appSettingsDao.updateFlatAreas(0);
        await database.appSettingsDao.updateAlbumArtColoredShade(enabled: true);
        await repository.saveOnboardingChanges(
          initial,
          initial.copyWith(themeMode: 'oled'),
        );
        var saved = await repository.getSettings();
        expect(saved.flatAreas.bits, 0);
        expect(saved.albumArtColoredShade, isTrue);
        await repository.saveOnboardingChanges(
          initial,
          initial.copyWith(
            flatAreas: const FlatAreas(nowPlaying: false),
            albumArtColoredShade: true,
          ),
        );
        saved = await repository.getSettings();
        expect(saved.flatAreas.bits, 5);
        expect(saved.albumArtColoredShade, isTrue);
        await repository.saveOnboardingChanges(
          saved,
          saved.copyWith(albumArtColoredShade: false),
        );
        expect((await repository.getSettings()).albumArtColoredShade, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test('corner style maps, saves, watches and resets', () async {
      final defaults = await repository.getSettings();
      expect(defaults.cornerStyle, NavisCornerStyle.rounded);
      expect(
        const AppSettingsModel.defaults().cornerStyle,
        NavisCornerStyle.rounded,
      );
      for (final style in NavisCornerStyle.values) {
        await database.appSettingsDao.updateCornerStyle(style.name);
        final targeted = await repository.getSettings();
        expect(targeted.cornerStyle, style);
        expect(targeted.copyWith(themeMode: 'oled').cornerStyle, style);
        await repository.saveSettings(
          targeted.copyWith(scrobbleEnabled: false),
        );
        expect((await repository.getSettings()).cornerStyle, style);
        expect(
          (await database.appSettingsDao.getSettings())!.cornerStyle,
          style.name,
        );
        final savedStyle = style == NavisCornerStyle.square
            ? NavisCornerStyle.soft
            : NavisCornerStyle.square;
        await database.appSettingsDao.updateCornerStyle(savedStyle.name);
        expect(
          (await repository.watchSettings().first).cornerStyle,
          savedStyle,
        );
        expect(
          (await database.appSettingsDao.getSettings())!.cornerStyle,
          savedStyle.name,
        );
      }
      await database.customStatement(
        "UPDATE app_settings SET corner_style = 'unknown'",
      );
      expect(
        (await repository.getSettings()).cornerStyle,
        NavisCornerStyle.rounded,
      );
    }, skip: !sqliteAvailable);

    test('background and density map, save and watch', () async {
      final defaults = await repository.getSettings();
      expect(defaults.nowPlayingBackground, NowPlayingBackground.tinted);
      expect(defaults.density, NavisDensity.comfortable);
      await database.appSettingsDao.updateNowPlayingBackground('artwork');
      await database.appSettingsDao.updateDensity(NavisDensity.compact);
      final targeted = await repository.getSettings();
      expect(targeted.nowPlayingBackground, NowPlayingBackground.artwork);
      expect(targeted.homeDensity, NavisDensity.compact);
      await repository.saveSettings(targeted.copyWith(scrobbleEnabled: false));
      expect(
        (await repository.getSettings()).nowPlayingBackground,
        NowPlayingBackground.artwork,
      );
      for (final background in NowPlayingBackground.values) {
        await database.appSettingsDao.updateNowPlayingBackground(
          background.storageKey,
        );
        await database.appSettingsDao.updateDensity(NavisDensity.compact);
        final watched = await repository.watchSettings().first;
        expect(watched.nowPlayingBackground, background);
        expect(watched.density, NavisDensity.compact);
        final row = (await database.appSettingsDao.getSettings())!;
        expect(row.nowPlayingBackground, background.storageKey);
      }
      await database.customStatement(
        "UPDATE app_settings SET now_playing_background = 'unknown', art_tinted_now_playing = 0, home_density = 'unknown'",
      );
      final unknown = await repository.getSettings();
      expect(unknown.nowPlayingBackground, NowPlayingBackground.tinted);
      expect(unknown.density, NavisDensity.comfortable);
    }, skip: !sqliteAvailable);

    test('stale onboarding drafts preserve setup release markers', () async {
      final stale = await repository.getSettings();
      await repository.updateSetupHighlightsSeenRelease('1.5.0');
      await repository.updateSetupCardDismissedRelease('1.5.0');
      await repository.saveSettings(stale.copyWith(scrobbleEnabled: false));
      final saved = await repository.getSettings();
      expect(saved.setupHighlightsSeenRelease, '1.5.0');
      expect(saved.setupCardDismissedRelease, '1.5.0');
      expect(saved.scrobbleEnabled, isFalse);
      final watched = await repository.watchSettings().first;
      expect(watched.setupHighlightsSeenRelease, '1.5.0');
      expect(watched.setupCardDismissedRelease, '1.5.0');
      final cleared = saved.copyWith(
        clearSetupHighlightsSeenRelease: true,
        clearSetupCardDismissedRelease: true,
      );
      expect(cleared.setupHighlightsSeenRelease, isNull);
      expect(cleared.setupCardDismissedRelease, isNull);
      expect(
        saved.copyWith(themeMode: 'oled').setupHighlightsSeenRelease,
        '1.5.0',
      );
    }, skip: !sqliteAvailable);

    test(
      'stale generic saves preserve integration switches and credentials',
      () async {
        await repository.updateListenBrainzConnection(
          tokenValid: true,
          userName: 'fixture',
          scrobblingEnabled: true,
        );
        final stale = await repository.getSettings();
        await repository.setIntegrationEnabled('lrclib.lyrics', enabled: false);
        await repository.setIntegrationEnabled(
          'updates.automatic',
          enabled: false,
        );
        await repository.setIntegrationEnabled(
          'lastfm.sameVibes',
          enabled: false,
        );
        await repository.setIntegrationEnabled(
          'listenbrainz.scrobbling',
          enabled: false,
        );
        await repository.updateListenBrainzConnection(tokenValid: false);
        await repository.saveSettings(stale.copyWith(scrobbleEnabled: false));
        final saved = await repository.getSettings();
        expect(saved.useLrclib, isFalse);
        expect(saved.updateCheckEnabled, isFalse);
        expect(saved.legacyInstantMixEnabled, isTrue);
        expect(saved.listenBrainzScrobblingEnabled, isFalse);
        expect(saved.listenBrainzTokenValid, isFalse);
        expect(saved.listenBrainzUserName, isNull);
        expect(saved.scrobbleEnabled, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test('stale saves cannot restore a cleared Last.fm key', () async {
      await repository.updateLastFmApiKey('fixture-key');
      final stale = await repository.getSettings();
      await repository.updateLastFmApiKey(null);
      await repository.saveSettings(stale);
      expect((await repository.getSettings()).lastFmApiKey, isNull);
      await repository.setIntegrationEnabled('lrclib.lyrics', enabled: false);
      await repository.updateLastFmApiKey('replacement-fixture-key');
      expect((await repository.getSettings()).useLrclib, isFalse);
    }, skip: !sqliteAvailable);

    test('the key writer writes only the key', () async {
      await repository.setIntegrationEnabled('lrclib.lyrics', enabled: false);
      await repository.updateListenBrainzConnection(
        tokenValid: true,
        userName: 'fixture',
        scrobblingEnabled: true,
      );
      await repository.updateLastFmApiKey('fixture-key');
      final saved = await repository.getSettings();
      expect(saved.lastFmApiKey, 'fixture-key');
      expect(saved.useLrclib, isFalse);
      expect(saved.listenBrainzTokenValid, isTrue);
      expect(saved.listenBrainzUserName, 'fixture');
      expect(saved.listenBrainzScrobblingEnabled, isTrue);
    }, skip: !sqliteAvailable);

    test('persists cached playback preference', () async {
      await repository.saveSettings(
        const AppSettingsModel.defaults().copyWith(cachedPlaybackFirst: true),
      );

      final saved = await repository.getSettings();
      expect(saved.cachedPlaybackFirst, isTrue);

      await repository.resetPlaybackDefaults();
      final reset = await repository.getSettings();
      expect(reset.cachedPlaybackFirst, isFalse);
    }, skip: !sqliteAvailable);

    test(
      'round trips appearance settings and keeps them through a playback reset',
      () async {
        final defaults = await repository.getSettings();
        expect(defaults.oledForAuto, isFalse);
        expect(defaults.nightScheduleEnabled, isFalse);
        expect(defaults.nightScheduleStartMinutes, 1320);
        expect(defaults.nightScheduleEndMinutes, 420);
        expect(defaults.flatSurfaces, isFalse);
        await database.appSettingsDao.updateOledForAuto(enabled: true);
        await database.appSettingsDao.updateNightSchedule(
          enabled: true,
          startMinutes: 1200,
          endMinutes: 480,
        );
        await database.appSettingsDao.updateFlatSurfaces(enabled: true);
        final saved = await repository.getSettings();
        expect(saved.oledForAuto, isTrue);
        expect(saved.nightScheduleEnabled, isTrue);
        expect(saved.nightScheduleStartMinutes, 1200);
        expect(saved.nightScheduleEndMinutes, 480);
        expect(saved.flatSurfaces, isTrue);
        await repository.saveSettings(saved.copyWith(scrobbleEnabled: false));
        final preserved = await repository.getSettings();
        expect(preserved.oledForAuto, isTrue);
        expect(preserved.nightScheduleEnabled, isTrue);
        expect(preserved.nightScheduleStartMinutes, 1200);
        expect(preserved.nightScheduleEndMinutes, 480);
        expect(preserved.flatSurfaces, isTrue);

        await repository.resetPlaybackDefaults();
        final afterPlaybackReset = await repository.getSettings();
        expect(afterPlaybackReset.oledForAuto, isTrue);
        expect(afterPlaybackReset.nightScheduleEnabled, isTrue);
        expect(afterPlaybackReset.flatSurfaces, isTrue);
      },
      skip: !sqliteAvailable,
    );

    test('targeted writer clamps Night schedule minutes', () async {
      await database.appSettingsDao.updateNightSchedule(
        startMinutes: -1,
        endMinutes: 1440,
      );
      final saved = await repository.getSettings();
      expect(saved.nightScheduleStartMinutes, 0);
      expect(saved.nightScheduleEndMinutes, 1439);
    }, skip: !sqliteAvailable);

    test('round trips colour style independently of theme mode', () async {
      final defaults = await repository.getSettings();
      expect(defaults.colorStyle, 'neutral');
      await database.appSettingsDao.updateThemeMode('oled');
      await database.appSettingsDao.updateColorStyle('pastel');

      final saved = await repository.getSettings();
      expect(saved.colorStyle, 'pastel');
      expect(saved.themeMode, 'oled');
      await database.appSettingsDao.updateThemeMode('light');
      expect((await repository.getSettings()).colorStyle, 'pastel');
    }, skip: !sqliteAvailable);

    test(
      'persists and normalizes desktop playback volume atomically',
      () async {
        await database.appSettingsDao.updateThemeMode('oled');

        await repository.saveDesktopPlaybackVolume(
          volume: 0.37,
          lastAudibleVolume: 0.37,
        );
        var saved = await repository.getSettings();
        expect(saved.desktopPlaybackVolume, 0.37);
        expect(saved.desktopLastAudibleVolume, 0.37);
        expect(saved.themeMode, 'oled');

        await repository.saveDesktopPlaybackVolume(
          volume: -1,
          lastAudibleVolume: 0,
        );
        saved = await repository.getSettings();
        expect(saved.desktopPlaybackVolume, 0);
        expect(saved.desktopLastAudibleVolume, 1);
      },
      skip: !sqliteAvailable,
    );
  });
}
