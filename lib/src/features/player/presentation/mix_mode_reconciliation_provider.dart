import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Keeps only the preferred mix backend active when settings change.
final mixModeReconciliationProvider =
    NotifierProvider.autoDispose<MixModeReconciliationController, int>(
      MixModeReconciliationController.new,
    );

class MixModeReconciliationController extends Notifier<int> {
  @override
  int build() {
    ref.listen<PreferredMixMode>(preferredMixModeProvider, (prev, next) {
      if (prev == null || prev == next) {
        return;
      }
      if (next == PreferredMixMode.legacyInstantMix) {
        ref.read(sameVibesProvider.notifier).deactivate();
      } else {
        ref.read(instantMixProvider.notifier).deactivate();
      }
    });
    return 0;
  }
}
