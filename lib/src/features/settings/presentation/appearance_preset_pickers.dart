import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common/preset_names.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/preset_picker.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/settings/presentation/appearance_options.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_controller.dart';

/// Why a preset or Look could not be saved, in the words of the name dialog
/// and of the notice shown for the other commands.
String presetFailureMessage(
  AppLocalizations l10n,
  PresetFailure failure, {
  bool look = false,
}) => switch (failure) {
  PresetFailure.emptyName => l10n.appearancePresetNameEmpty,
  PresetFailure.duplicateName => l10n.appearancePresetNameTaken,
  PresetFailure.reservedName => l10n.appearancePresetNameReserved,
  PresetFailure.notFound =>
    look ? l10n.appearanceLooksMissing : l10n.appearancePresetMissing,
  PresetFailure.persistence => l10n.appearancePresetSaveFailure,
};

/// Shared wording for saved Looks.
PresetPickerLabels _labels(
  AppLocalizations l10n, {
  required String custom,
  required String picker,
  required String actions,
  required String saveNew,
  required String nameField,
}) => PresetPickerLabels(
  picker: picker,
  custom: custom,
  actions: actions,
  saveNew: saveNew,
  update: l10n.appearancePresetUpdateNamed,
  rename: l10n.appearancePresetRenameNamed,
  delete: l10n.appearancePresetDeleteNamed,
  deleteConfirm: l10n.appearancePresetDeleteConfirm,
  renameTitle: l10n.commonRename,
  nameField: nameField,
  cancel: l10n.commonCancel,
  save: l10n.commonSave,
  deleteAction: l10n.commonDelete,
  discard: l10n.eqDiscardChanges,
  discardShort: l10n.eqDiscard,
  discardConfirm: l10n.presetDiscardConfirm,
);

/// Saved Looks at the top of Appearance settings.
///
/// Choosing a Look applies its whole appearance through
/// [AppearanceLooksController].
///
/// With no Looks the picker reads Custom (the current appearance) and its menu
/// offers the first save, which the subtitle points to. A changed appearance
/// reads "`Look`*" and Update saves over that Look, which is the stored
/// selection, so it survives leaving the page and restarts; Discard re-applies
/// that Look.
class AppearanceLooksOption extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<AppearanceLooksOption> createState() =>
      _AppearanceLooksOptionState();
}

class _AppearanceLooksOptionState extends ConsumerState<AppearanceLooksOption> {
  void _notice(PresetFailure? failure) {
    if (failure == null || !mounted) return;
    showAppNotice(
      context,
      message: presetFailureMessage(
        AppLocalizations.of(context)!,
        failure,
        look: true,
      ),
      level: AppNoticeLevel.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(appearanceLooksControllerProvider);
    final controller = ref.read(appearanceLooksControllerProvider.notifier);
    final selected = state.selectedLookId;
    final origin = state.originLookId;
    return HighlightedAppearanceOption(
      highlight: SetupHighlight.appearanceLooks,
      builder: (context, adornment) => AppearanceChoiceSection(
        title: l10n.appearanceLooksLabel,
        adornment: adornment,
        description: state.looks.isEmpty
            ? l10n.appearanceLooksSubEmpty
            : l10n.appearanceLooksSub,
        selector: PresetPicker(
          keyPrefix: 'appearanceLook',
          icon: Icons.style_outlined,
          selectedId: selected,
          entries: <PresetPickerEntry>[
            for (final look in state.looks)
              PresetPickerEntry(id: look.id, label: look.name),
          ],
          updateId: selected == null ? origin : null,
          manageId: selected ?? origin,
          labels: _labels(
            l10n,
            custom: l10n.appearancePresetCustom,
            picker: l10n.appearanceLooksPicker,
            actions: l10n.appearanceLooksActions,
            saveNew: l10n.appearanceLooksSaveNew,
            nameField: l10n.appearanceLooksName,
          ),
          onSelect: (id) async {
            final name = state.looks
                .where((look) => look.id == id)
                .firstOrNull
                ?.name;
            final previous = await controller.apply(id);
            if (previous == null) return _notice(PresetFailure.persistence);
            if (name == null || !context.mounted) return;
            showAppNotice(
              context,
              message: l10n.appearanceLooksApplied(name),
              duration: const Duration(seconds: 6),
              actionLabel: l10n.commonUndo,
              onAction: () async => _notice(await controller.restore(previous)),
            );
          },
          onSaveNew: (name) async {
            final failure = (await controller.saveAsNew(name)).failure;
            return failure == null
                ? null
                : presetFailureMessage(l10n, failure, look: true);
          },
          onUpdate: (id) async => _notice(await controller.update(id)),
          onDiscard: (id) async {
            if (await controller.apply(id) == null) {
              _notice(PresetFailure.persistence);
            }
          },
          onRename: (id, name) async {
            final failure = await controller.rename(id, name);
            return failure == null
                ? null
                : presetFailureMessage(l10n, failure, look: true);
          },
          onDelete: (id) async => _notice(await controller.delete(id)),
        ),
      ),
    );
  }
}
