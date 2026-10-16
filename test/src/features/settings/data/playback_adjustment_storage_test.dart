import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';

import '../../../../helpers/test_database.dart';

void main() {
  test('targeted playback writes survive stale settings save and reset retains presets', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final repository = SettingsRepository(database.appSettingsDao);
    await repository.getSettings();
    const values = PlaybackAdjustments(speed: 1.1375, lockPitchToSpeed: true);
    const preset = PlaybackPreset(id: 'p1', name: 'Slow', values: values);
    await repository.savePlaybackAdjustments(
      values: values,
      selectedPresetId: 'p1',
      presets: [preset],
    );
    await repository.saveSettings(
      const AppSettingsModel.defaults().copyWith(scrobbleEnabled: false),
    );
    var saved = await repository.getSettings();
    expect(saved.playbackSpeed, values.speed);
    expect(saved.playbackPitchSemitones, values.pitchSemitones);
    expect(saved.lockPitchToSpeed, isTrue);
    expect(saved.selectedPlaybackPresetId, 'p1');
    expect(saved.playbackPresets.single.values, values);
    expect(saved.scrobbleEnabled, isFalse);
    await repository.resetDefaults();
    saved = await repository.getSettings();
    expect(saved.playbackSpeed, 1);
    expect(saved.playbackPitchSemitones, 0);
    expect(saved.lockPitchToSpeed, isFalse);
    expect(saved.selectedPlaybackPresetId, 'none');
    expect(saved.playbackPresets.single.name, 'Slow');
  }, skip: !sqliteAvailable);
}
