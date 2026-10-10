import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/theme/color_adjustment.dart';

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

  test('tuning JSON drops corrupt records, duplicate ids and names', () {
    const preset = ColorTuningPreset(
      id: 'a',
      name: ' Warm ',
      tuning: ColorTuning(vividness: 2, lightDepth: -1, darkDepth: 3),
    );
    final json = preset.toJson();
    final decoded = decodeColorTuningPresets(
      jsonEncode([
        json,
        null,
        1,
        <String, Object?>{},
        {...json, 'id': 'b', 'name': 'warm'},
        {...json, 'name': 'Other'},
        {...json, 'id': 'c', 'vividness': 6},
        {...json, 'id': 'd', 'darkDepth': 1.5},
        {...json, 'id': 'default'},
        {...json, 'id': 'e', 'name': 'Default'},
        {...json, 'id': '', 'name': 'Empty'},
        {...json, 'id': 'f', 'name': 'Second'},
      ]),
    );
    expect(decoded.map((p) => p.id), ['a', 'f']);
    expect(decoded.first.name, 'Warm');
    expect(decoded.first.tuning, preset.tuning);
    for (final raw in ['bad', '{}', 'null']) {
      expect(decodeColorTuningPresets(raw), isEmpty);
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

  test(
    'snapshot identity ignores tuning reference, includes every captured value',
    () {
      final captured = AppearanceSnapshot.capture(
        const AppSettingsModel.defaults(),
      );
      final json = captured.toJson();
      expect(AppearanceSnapshot.fromJson(json), captured);
      expect(
        AppearanceSnapshot.fromJson({...json, 'tuningPresetId': 'deleted'}),
        captured,
      );
      for (final key in json.keys.where((k) => k != 'tuningPresetId')) {
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
    },
  );
}
