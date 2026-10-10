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
      expect(container.read(colorAdjustmentProvider), ColorAdjustment.none);
      expect(
        container.read(effectiveColorAdjustmentProvider),
        ColorAdjustment.none,
      );
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
                surfaceDepth: 4,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      const saved = ColorAdjustment(vividness: -3, depth: 4);
      const preview = ColorAdjustment(vividness: 5, depth: -5);
      expect(container.read(colorAdjustmentProvider), saved);
      final notifier = container.read(colorAdjustmentPreviewProvider.notifier);
      notifier.preview(preview);
      expect(container.read(colorAdjustmentProvider), saved);
      expect(container.read(effectiveColorAdjustmentProvider), preview);
      notifier.clear();
      expect(container.read(colorAdjustmentPreviewProvider), isNull);
      expect(container.read(effectiveColorAdjustmentProvider), saved);
    },
  );
}
