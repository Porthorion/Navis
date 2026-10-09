import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_corner_style.dart';

/// Saved chrome corner style, defaulting to rounded while settings load.
final cornerStyleProvider = Provider<NavisCornerStyle>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.cornerStyle;
});
