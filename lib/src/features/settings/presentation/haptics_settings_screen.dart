import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/async_body.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/common_widgets/navis_switch.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Settings › Haptics (phones and tablets): one master switch and one switch
/// per [HapticCategory].
///
/// Every switch writes at once through the targeted haptics writers. While the
/// master is off the category tiles are disabled but keep their stored values,
/// so turning it back on restores the exact previous mix.
class HapticsSettingsScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.hapticsTitle)),
      body: AsyncBody(
        value: ref.watch(appSettingsProvider),
        data: (settings) => _content(context, ref, settings.hapticsPrefs),
        errorTitle: l10n.hapticsLoadError,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
    );
  }

  Widget _content(BuildContext context, WidgetRef ref, HapticsPrefs prefs) {
    final l10n = AppLocalizations.of(context)!;
    final copy = <HapticCategory, (String, String)>{
      HapticCategory.playerGestures: (
        l10n.hapticsPlayerGesturesTitle,
        l10n.hapticsPlayerGesturesSubtitle,
      ),
      HapticCategory.playbackButtons: (
        l10n.hapticsPlaybackButtonsTitle,
        l10n.hapticsPlaybackButtonsSubtitle,
      ),
      HapticCategory.slidersAndRulers: (
        l10n.hapticsSlidersAndRulersTitle,
        l10n.hapticsSlidersAndRulersSubtitle,
      ),
      HapticCategory.switchesAndSteppers: (
        l10n.hapticsSwitchesAndSteppersTitle,
        l10n.hapticsSwitchesAndSteppersSubtitle,
      ),
      HapticCategory.listsAndMenus: (
        l10n.hapticsListsAndMenusTitle,
        l10n.hapticsListsAndMenusSubtitle,
      ),
      HapticCategory.likesAndAlerts: (
        l10n.hapticsLikesAndAlertsTitle,
        l10n.hapticsLikesAndAlertsSubtitle,
      ),
    };
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            NavisSpace.md,
            NavisSpace.xs,
            NavisSpace.md,
            NavisSpace.xxl,
          ),
          children: <Widget>[
            NavisSwitchListTile(
              key: const ValueKey<String>('haptics-master'),
              contentPadding: EdgeInsets.zero,
              // The master clicks for itself, whatever the preferences say,
              // so the user feels this switch work in both directions.
              haptic: false,
              value: prefs.enabled,
              onChanged: (value) {
                NavisHaptics.masterToggle(value);
                unawaited(
                  _write(
                    context,
                    ref,
                    (repository) =>
                        repository.setHapticsEnabled(enabled: value),
                  ),
                );
              },
              title: Text(l10n.hapticsMasterTitle),
              subtitle: Text(l10n.hapticsMasterSubtitle),
            ),
            const Divider(height: NavisSpace.lg),
            for (final category in HapticCategory.values)
              NavisSwitchListTile(
                key: ValueKey<String>('haptics-${category.name}'),
                contentPadding: EdgeInsets.zero,
                // The stored choice shows even while locked.
                value: prefs.isOn(category),
                onChanged: prefs.enabled
                    ? (value) => unawaited(
                        _write(
                          context,
                          ref,
                          (repository) => repository.setHapticCategoryEnabled(
                            category,
                            enabled: value,
                          ),
                        ),
                      )
                    : null,
                title: Text(copy[category]!.$1),
                subtitle: Text(copy[category]!.$2),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _write(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function(SettingsRepository repository) write,
  ) async {
    try {
      await write(ref.read(settingsRepositoryProvider));
    } on Object catch (error, stackTrace) {
      AppLogger.error('Haptics switch could not be saved', error, stackTrace);
      if (!context.mounted) return;
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!.hapticsSaveError,
        level: AppNoticeLevel.error,
      );
    }
  }
}
