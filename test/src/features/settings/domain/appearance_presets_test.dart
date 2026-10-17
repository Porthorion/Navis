import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/routing/content_layout.dart';

void main() {
  test('tuning clamps and resolves Light independently from Dark and OLED', () {
    const tuning = ColorTuning(vividness: 20, lightDepth: -20, darkDepth: 3);
    expect(
      tuning.forMode(dark: false),
      const ColorAdjustment(vividness: 5, depth: -5),
    );
    expect(
      tuning.forMode(dark: true),
      const ColorAdjustment(vividness: 5, depth: 3),
    );
    expect(
      tuning,
      const ColorTuning(vividness: 5, lightDepth: -5, darkDepth: 3),
    );
    expect(
      tuning.hashCode,
      const ColorTuning(vividness: 5, lightDepth: -5, darkDepth: 3).hashCode,
    );
    expect(ColorTuning.none.forMode(dark: false), ColorAdjustment.none);
    expect(ColorTuning.none.forMode(dark: true), ColorAdjustment.none);
  });

  test('Tint and Controls clamp, resolve, copy and decode leniently', () {
    const tuning = ColorTuning(
      lightTint: 99,
      darkTint: -3,
      controls: NavisControlColor.white,
    );
    expect(tuning.lightTint, 5);
    expect(tuning.darkTint, 0);
    expect(const ColorAdjustment(tint: 99).tint, 5);
    for (final tint in [-3, -1, 0]) {
      expect(ColorAdjustment(tint: tint).tint, 0);
    }
    expect(tuning.forMode(dark: false).tint, 5);
    expect(tuning.forMode(dark: true).controls, NavisControlColor.white);
    expect(tuning.copyWith(darkTint: 3).lightTint, 5);
    expect(tuning.copyWith(darkTint: 3).controls, NavisControlColor.white);
    final settings = const AppSettingsModel.defaults().copyWith(
      surfaceTintLight: 5,
      surfaceTintDark: 3,
      controlColor: 'white',
    );
    final captured = AppearanceSnapshot.capture(settings);
    expect(AppearanceSnapshot.fromJson(captured.toJson()), captured);
    expect(settings.colorTuning, tuning.copyWith(darkTint: 3));
    for (final value in [null, -1, 6, 1.5, '3']) {
      expect(
        AppearanceSnapshot.fromJson({
          'surfaceTintLight': value,
          'surfaceTintDark': value,
        }).toJson(),
        isEmpty,
      );
    }
    for (final value in [null, 'unknown', 1, true]) {
      expect(
        AppearanceSnapshot.fromJson({'controlColor': value}).toJson(),
        isEmpty,
      );
    }
  });

  test('accent swatches share lenient ARGB decoding with Look snapshots', () {
    expect(decodeAccentSeeds('[0,4294967295]'), [0, 0xFFFFFFFF]);
    for (final raw in [
      null,
      '',
      'bad',
      '{}',
      '[1,-1]',
      '[1,1.5]',
      '["blue"]',
    ]) {
      expect(decodeAccentSeeds(raw), isEmpty);
    }
  });

  test(
    'Looks decode version 1 only, keep valid optional fields and dedupe',
    () {
      final look = AppearanceLook(
        id: 'a',
        name: 'Warm',
        snapshot: AppearanceSnapshot.capture(const AppSettingsModel.defaults()),
      );
      final json = look.toJson();
      final decoded = decodeAppearanceLooks(
        jsonEncode([
          json,
          <String, Object?>{},
          null,
          {...json, 'id': 'b', 'name': 'WARM'},
          {...json, 'name': 'Other'},
          {...json, 'id': 'c', 'version': 2},
          {...json, 'id': 'd', 'snapshot': 'broken'},
          {
            ...json,
            'id': 'e',
            'name': 'Partial',
            'snapshot': {
              'themeMode': 'unknown',
              'oledForAuto': 'bad',
              'surfaceDepthLight': 6,
              'nightScheduleStartMinutes': 1440,
              'flatAreas': -1,
              'colorSchemeSeed': -1,
              'cornerStyle': null,
              'artistViewMode': 'list',
              'colorVividness': -2,
              'futureField': true,
            },
          },
        ]),
      );
      expect(decoded.map((p) => p.id), ['a', 'e']);
      expect(decoded.first.snapshot, look.snapshot);
      expect(decoded.last.snapshot.toJson(), {
        'artistViewMode': 'list',
        'colorVividness': -2,
      });
      for (final raw in ['bad', '{}', 'null']) {
        expect(decodeAppearanceLooks(raw), isEmpty);
      }
    },
  );

  final layoutEdits = <String, AppSettingsModel>{
    'coverArtShape': const AppSettingsModel.defaults().copyWith(
      coverArtShape: 'circle',
    ),
    'nowPlayingArtShape': const AppSettingsModel.defaults().copyWith(
      nowPlayingArtShape: 'square',
    ),
    'artistCardShape': const AppSettingsModel.defaults().copyWith(
      artistCardShape: 'rounded',
    ),
    'gridArtworkSize': const AppSettingsModel.defaults().copyWith(
      gridArtworkSize: GridArtworkSize.large,
    ),
    'density': const AppSettingsModel.defaults().copyWith(
      density: NavisDensity.compact,
    ),
    'artistViewMode': const AppSettingsModel.defaults().copyWith(
      artistViewMode: 'list',
    ),
    'albumGridDensity': const AppSettingsModel.defaults().copyWith(
      albumGridDensity: 6,
    ),
  };
  final layoutJson = <String, Object?>{
    'coverArtShape': 'circle',
    'nowPlayingArtShape': 'square',
    'artistCardShape': 'rounded',
    'gridArtworkSize': 'large',
    'density': 'compact',
    'artistViewMode': 'list',
    'albumGridDensity': 6,
  };
  for (final entry in layoutEdits.entries) {
    test('${entry.key} is captured, round-trips and makes the Look Custom', () {
      final captured = AppearanceSnapshot.capture(
        const AppSettingsModel.defaults(),
      );
      final look = AppearanceLook(id: 'base', name: 'Base', snapshot: captured);
      final edited = entry.value.copyWith(
        appearanceLooks: [look],
        selectedAppearanceLookId: look.id,
      );
      final snapshot = AppearanceSnapshot.capture(edited);
      expect(snapshot.toJson()[entry.key], layoutJson[entry.key]);
      expect(AppearanceSnapshot.fromJson(snapshot.toJson()), snapshot);
      expect(snapshot, isNot(captured));
      expect(matchingAppearanceLookId(edited), isNull);
      expect(storedAppearanceLookId(edited), look.id);
    });

    test(
      'missing ${entry.key} matches without weakening snapshot equality',
      () {
        final full = AppearanceSnapshot.capture(
          const AppSettingsModel.defaults(),
        );
        final json = full.toJson()..remove(entry.key);
        final partial = AppearanceSnapshot.fromJson(json);
        final look = AppearanceLook(
          id: 'partial',
          name: 'Partial',
          snapshot: partial,
        );
        expect(partial, isNot(full));
        expect(
          matchingAppearanceLookId(
            entry.value.copyWith(
              appearanceLooks: [look],
              selectedAppearanceLookId: look.id,
            ),
          ),
          look.id,
        );
      },
    );
  }

  test('version-1 Looks read layout keys again', () {
    final look = AppearanceLook.fromJson({
      'id': 'old',
      'name': 'Old',
      'version': 1,
      'snapshot': layoutJson,
    })!;
    expect(look.snapshot.toJson(), layoutJson);
    expect(
      AppearanceSnapshot.fromJson(const {'albumGridDensity': null}).toJson(),
      {'albumGridDensity': null},
    );
    for (final invalid in [0, 101, '6']) {
      expect(
        AppearanceSnapshot.fromJson({'albumGridDensity': invalid}).toJson(),
        isEmpty,
      );
    }
  });

  test('snapshot ignores retired tuning reference and includes every captured value', () {
    final captured = AppearanceSnapshot.capture(
      const AppSettingsModel.defaults(),
    );
    final json = captured.toJson();
    expect(AppearanceSnapshot.fromJson(json), captured);
    expect(
      AppearanceSnapshot.fromJson({...json, 'tuningPresetId': 'deleted'}),
      captured,
    );
    expect(
      AppearanceSnapshot.fromJson({...json, 'tuningPresetId': 'deleted'})
          .toJson(),
      json,
    );
    expect(json, isNot(contains('tuningPresetId')));
    for (final key in json.keys) {
      final modified = {...json}..remove(key);
      expect(
        AppearanceSnapshot.fromJson(modified),
        isNot(captured),
        reason: key,
      );
    }
    expect(json.keys, isNot(contains('homeSectionsHidden')));
    expect(json.keys, isNot(contains('showArtistsPage')));
    expect(json.keys, isNot(contains('desktopNavbarStyle')));
  });
}
