import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';

void main() {
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
          dynamicAccentSeedColorProvider.overrideWith(
            (_) async => 0xFFABCDEF,
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(dynamicAccentSeedColorProvider.future);
      final effective = container.read(effectiveColorSchemeSeedProvider);

      expect(effective, 0xFFABCDEF);
    });
  });
}
