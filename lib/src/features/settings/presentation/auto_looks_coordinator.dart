import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/settings/domain/auto_theme.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_controller.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Applies the Look chosen for Auto's current light or dark mode.
///
/// Listened to once from the app root. A switch to a mode that is not the last
/// applied one applies that mode's Look; so does turning the switch on or
/// changing the current mode's choice. Starting in the same mode applies
/// nothing, so tweaks survive until the next switch. The Look applies through
/// [AppearanceLooksController] without the fields Auto owns
/// ([autoLookSnapshot]), so it never changes the theme mode. None or a deleted
/// Look applies nothing.
class AutoLooksCoordinator extends Notifier<void> {
  Future<void> _queue = Future<void>.value();

  @override
  void build() {
    ref
      ..listen(effectiveDarkProvider, (_, _) => _enqueue(force: false))
      ..listen(
        appSettingsProvider.select((s) {
          final v = s.asData?.value;
          return v == null
              ? null
              : (
                  enabled: v.autoLooksEnabled,
                  light: v.autoLightLookId,
                  dark: v.autoDarkLookId,
                );
        }),
        (prev, next) {
          if (next == null) return;
          final isDark = ref.read(effectiveDarkProvider);
          // First load: reconcile like a start. Later: the user's own change.
          if (prev == null || isDark == null || !next.enabled) {
            return _enqueue(force: false);
          }
          final choiceChanged = isDark
              ? prev.dark != next.dark
              : prev.light != next.light;
          if (!prev.enabled || choiceChanged) _enqueue(force: true);
        },
      );
    scheduleMicrotask(() => _enqueue(force: false));
  }

  /// Runs reconciles one at a time; each reads fresh settings, so repeats
  /// collapse into no-ops.
  void _enqueue({required bool force}) {
    _queue = _queue.then((_) => _reconcile(force: force));
  }

  Future<void> _reconcile({required bool force}) async {
    try {
      // Not Auto, or presets off: nothing to do, and no database read.
      if (!ref.mounted || ref.read(effectiveDarkProvider) == null) return;
      final cached = ref.read(appSettingsProvider).asData?.value;
      if (cached == null || !cached.autoLooksEnabled) return;
      final repository = ref.read(settingsRepositoryProvider);
      final settings = await repository.getSettings();
      final isDark = ref.read(effectiveDarkProvider);
      if (!ref.mounted || isDark == null || !settings.autoLooksEnabled) return;
      final mode = AutoMode.of(isDark: isDark);
      if (!force && settings.autoLooksAppliedMode == mode) return;
      final id = isDark ? settings.autoDarkLookId : settings.autoLightLookId;
      if (id != null && settings.appearanceLooks.any((look) => look.id == id)) {
        final applied = await ref
            .read(appearanceLooksControllerProvider.notifier)
            .apply(id, only: autoLookSnapshot);
        // Failed: leave the mode unrecorded so the next trigger retries.
        if (applied == null) return;
      }
      if (!ref.mounted) return;
      await ref
          .read(navisDatabaseProvider)
          .appSettingsDao
          .updateAutoLooksAppliedMode(mode);
    } on Object {
      // Best effort: the next switch or settings change tries again.
    }
  }
}

final autoLooksCoordinatorProvider =
    NotifierProvider<AutoLooksCoordinator, void>(AutoLooksCoordinator.new);
