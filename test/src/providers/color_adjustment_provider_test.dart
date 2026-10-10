import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/color_adjustment.dart';

void main() {
  for (final settings in [
    const AsyncLoading<AppSettingsModel>(),
    AsyncError<AppSettingsModel>(StateError('offline'), StackTrace.empty),
  ]) {
    test('color tuning falls back to identity for $settings', () {
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWithValue(settings)],
      );
      addTearDown(container.dispose);
      expect(container.read(colorTuningProvider), ColorTuning.none);
      expect(container.read(effectiveColorTuningProvider), ColorTuning.none);
    });
  }
  test(
    'preview overrides persisted values and clear restores current settings',
    () {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                colorVividness: -3,
                surfaceDepthLight: 4,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      const saved = ColorTuning(vividness: -3, lightDepth: 4);
      const preview = ColorTuning(vividness: 5, lightDepth: -5);
      expect(container.read(colorTuningProvider), saved);
      final notifier = container.read(colorTuningPreviewProvider.notifier);
      notifier.preview(preview);
      expect(container.read(colorTuningProvider), saved);
      expect(container.read(effectiveColorTuningProvider), preview);
      notifier.clear();
      expect(container.read(colorTuningPreviewProvider), isNull);
      expect(container.read(effectiveColorTuningProvider), saved);
    },
  );
}
