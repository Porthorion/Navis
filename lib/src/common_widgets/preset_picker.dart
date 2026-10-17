import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/confirm_dialog.dart';

/// One choice in a [PresetPicker].
@immutable
class PresetPickerEntry {
  const new({
    required this.id,
    required this.label,
    this.icon,
    this.enabled = true,
    this.disabledReason,
  });

  final String id;
  final String label;

  /// Leading icon; the picker's own `icon` when null.
  final IconData? icon;

  /// A disabled entry stays listed, with [disabledReason] as the tooltip of
  /// its block icon.
  final bool enabled;
  final String? disabledReason;
}

/// Every string a [PresetPicker] shows, so callers keep their own wording.
@immutable
class PresetPickerLabels {
  const new({
    required this.picker,
    required this.custom,
    required this.actions,
    required this.saveNew,
    required this.update,
    required this.rename,
    required this.delete,
    required this.deleteConfirm,
    required this.nameField,
    required this.renameTitle,
    required this.cancel,
    required this.save,
    required this.deleteAction,
    required this.discard,
    required this.discardConfirm,
  });

  /// The dropdown's floating label.
  final String picker;

  /// The entry shown while the values match no preset.
  final String custom;

  /// Tooltip of the ⋮ button.
  final String actions;
  final String saveNew;
  final String renameTitle;
  final String nameField;

  /// Menu items that act on a named preset.
  final String Function(String name) update;
  final String Function(String name) rename;
  final String Function(String name) delete;

  /// The delete confirmation's title.
  final String Function(String name) deleteConfirm;
  final String cancel;
  final String save;

  /// The confirmation's destructive button.
  final String deleteAction;

  /// The menu item, and the confirm button, that drop the edits made to a
  /// preset and re-apply it.
  final String discard;

  /// The discard confirmation's message.
  final String Function(String name) discardConfirm;
}

/// A compact preset dropdown with a ⋮ menu to save, update, rename and delete
/// presets, independent of what a preset holds.
///
/// The dropdown lists [entries] (a "Custom" entry first while [selectedId] is
/// null). The menu acts on [updateId] (Update) and [manageId] (Rename and
/// Delete); a null id hides its item. While [selectedId] is null and
/// [updateId] names the preset being edited, the entry reads `<name>*`, like
/// the equalizer's unsaved changes, and [onDiscard] (when given) adds a
/// confirmed Discard item that re-applies that preset. Name validation belongs to the callers:
/// [onSaveNew] and [onRename] return an error shown inline in the name dialog,
/// or null once saved.
///
/// [keyPrefix] names the widgets (`<prefix>Dropdown`, `Actions`, `SaveNew`,
/// `Update`, `Rename`, `Delete`, `DeleteConfirm`, `Discard`, `DiscardConfirm`,
/// `NameInput`).
class PresetPicker extends StatefulWidget {
  const new({
    required this.entries,
    required this.selectedId,
    required this.labels,
    required this.icon,
    required this.onSelect,
    required this.onSaveNew,
    required this.onRename,
    required this.onDelete,
    this.onUpdate,
    this.onDiscard,
    this.updateId,
    this.manageId,
    this.enabled = true,
    this.keyPrefix = 'preset',
    super.key,
  });

  final List<PresetPickerEntry> entries;

  /// The chosen entry; null means the values match none ("Custom").
  final String? selectedId;
  final PresetPickerLabels labels;
  final IconData icon;
  final bool enabled;
  final String keyPrefix;

  /// The preset Update overwrites, typically the one being edited.
  final String? updateId;

  /// The preset Rename and Delete act on: the selected one, else the one being
  /// edited.
  final String? manageId;

  final Future<void> Function(String id) onSelect;
  final Future<String?> Function(String name) onSaveNew;
  final Future<void> Function(String id)? onUpdate;

  /// Re-applies the preset the values were edited from.
  final Future<void> Function(String id)? onDiscard;
  final Future<String?> Function(String id, String name) onRename;
  final Future<void> Function(String id) onDelete;

  @override
  State<PresetPicker> createState() => _PresetPickerState();
}

class _PresetPickerState extends State<PresetPicker> {
  static const _customId = 'custom';

  PresetPickerEntry? _entry(String? id) =>
      widget.entries.where((e) => e.id == id).firstOrNull;

  ValueKey<String> _key(String suffix) =>
      ValueKey<String>('${widget.keyPrefix}$suffix');

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final selected = widget.selectedId;
    final update = _entry(widget.updateId);
    final edited = selected == null ? update : null;
    final entries = <DropdownMenuEntry<String>>[
      if (selected == null)
        DropdownMenuEntry(
          value: _customId,
          label: edited == null ? labels.custom : '${edited.label}*',
          leadingIcon: const Icon(Icons.tune, size: 20),
        ),
      for (final entry in widget.entries)
        DropdownMenuEntry(
          value: entry.id,
          label: entry.label,
          leadingIcon: Icon(entry.icon ?? widget.icon, size: 20),
          enabled: entry.enabled,
          trailingIcon: entry.enabled
              ? null
              : Tooltip(
                  message: entry.disabledReason ?? '',
                  child: const Icon(Icons.block, size: 18),
                ),
        ),
    ];
    final shown = selected ?? _customId;
    final shownEntry = entries.where((e) => e.value == shown).firstOrNull;
    final manage = _entry(widget.manageId);
    Widget menuLabel(String text) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return Row(
      children: [
        Expanded(
          // Keyed by the shown selection so external changes (presets,
          // edits, the pinned reset) refresh the field text.
          child: KeyedSubtree(
            key: ValueKey<String>(
              '${widget.keyPrefix}-$shown-${shownEntry?.label}',
            ),
            // A long name wraps (up to three lines) instead of being cut off;
            // the field only grows when the name needs it.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final lines = _lines(
                  context,
                  shownEntry?.label ?? '',
                  constraints.maxWidth,
                );
                return DropdownMenu<String>(
                  key: _key('Dropdown'),
                  enabled: widget.enabled,
                  expandedInsets: EdgeInsets.zero,
                  requestFocusOnTap: false,
                  maxLines: lines,
                  menuHeight: 320,
                  label: Text(labels.picker),
                  leadingIcon: shownEntry?.leadingIcon,
                  initialSelection: shown,
                  dropdownMenuEntries: entries,
                  onSelected: (id) {
                    if (id == null || id == _customId || id == selected) return;
                    unawaited(widget.onSelect(id));
                  },
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 4),
        MenuAnchor(
          builder: (context, menu, _) => IconButton(
            key: _key('Actions'),
            tooltip: labels.actions,
            onPressed: widget.enabled
                ? () => menu.isOpen ? menu.close() : menu.open()
                : null,
            icon: const Icon(Icons.more_vert),
          ),
          menuChildren: [
            MenuItemButton(
              key: _key('SaveNew'),
              leadingIcon: const Icon(Icons.add),
              onPressed: () => unawaited(_nameDialog()),
              child: Text(labels.saveNew),
            ),
            if (update != null && widget.onUpdate != null)
              MenuItemButton(
                key: _key('Update'),
                leadingIcon: const Icon(Icons.save_outlined),
                onPressed: () => unawaited(widget.onUpdate!(update.id)),
                child: menuLabel(labels.update(update.label)),
              ),
            if (edited != null && widget.onDiscard != null)
              MenuItemButton(
                key: _key('Discard'),
                leadingIcon: const Icon(Icons.restore),
                onPressed: () => unawaited(_confirmDiscard(edited)),
                child: Text(labels.discard),
              ),
            for (final entry in widget.entries.where(
              (e) => !e.enabled && e.id != manage?.id,
            ))
              MenuItemButton(
                leadingIcon: const Icon(Icons.delete_outline),
                onPressed: () => unawaited(_confirmDelete(entry)),
                child: menuLabel(labels.delete(entry.label)),
              ),
            if (manage != null) ...[
              MenuItemButton(
                key: _key('Rename'),
                leadingIcon: const Icon(Icons.edit_outlined),
                onPressed: () => unawaited(_nameDialog(rename: manage)),
                child: menuLabel(labels.rename(manage.label)),
              ),
              MenuItemButton(
                key: _key('Delete'),
                leadingIcon: const Icon(Icons.delete_outline),
                onPressed: () => unawaited(_confirmDelete(manage)),
                child: menuLabel(labels.delete(manage.label)),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Lines (1 to 3) [text] needs in the field, measured against the width
  /// left after its padding and icons. Leaving a little more room than they
  /// take only makes the field taller early, never cuts the text.
  int _lines(BuildContext context, String text, double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: Theme.of(context).textTheme.bodyLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 3,
    )..layout(maxWidth: (width - 120).clamp(1, double.infinity));
    final lines = painter.computeLineMetrics().length;
    painter.dispose();
    return lines.clamp(1, 3);
  }

  Future<void> _confirmDiscard(PresetPickerEntry preset) async {
    final labels = widget.labels;
    final discard = await showConfirmDialog(
      context,
      title: labels.discard,
      message: labels.discardConfirm(preset.label),
      confirmLabel: labels.discard,
      cancelLabel: labels.cancel,
      confirmKey: _key('DiscardConfirm'),
    );
    if (discard && mounted) await widget.onDiscard!(preset.id);
  }

  Future<void> _confirmDelete(PresetPickerEntry preset) async {
    final labels = widget.labels;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          labels.deleteConfirm(preset.label),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(labels.cancel),
          ),
          FilledButton(
            key: _key('DeleteConfirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(labels.deleteAction),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await widget.onDelete(preset.id);
  }

  Future<void> _nameDialog({PresetPickerEntry? rename}) {
    final labels = widget.labels;
    return showDialog<String>(
      context: context,
      builder: (context) => TextEntryDialog(
        title: rename == null ? labels.saveNew : labels.renameTitle,
        initialText: rename?.label ?? '',
        fieldKey: _key('NameInput'),
        fieldLabel: labels.nameField,
        confirmLabel: labels.save,
        cancelLabel: labels.cancel,
        onSubmit: (raw) => rename == null
            ? widget.onSaveNew(raw)
            : widget.onRename(rename.id, raw),
      ),
    );
  }
}

/// A one-field dialog whose [onSubmit] validates and applies the text,
/// returning an error to show under the field or null to close with the text.
/// Used for preset names and, with [numeric], for exact number entry.
class TextEntryDialog extends StatefulWidget {
  const new({
    required this.title,
    required this.initialText,
    required this.onSubmit,
    required this.confirmLabel,
    required this.cancelLabel,
    this.fieldKey,
    this.fieldLabel,
    this.numeric = false,
    super.key,
  });

  final String title;
  final String initialText;
  final Future<String?> Function(String text) onSubmit;
  final String confirmLabel;
  final String cancelLabel;
  final Key? fieldKey;
  final String? fieldLabel;

  /// Shows the signed decimal keyboard.
  final bool numeric;

  @override
  State<TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<TextEntryDialog> {
  late final TextEditingController _input;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initialText);
  }

  Future<void> _submit() async {
    setState(() => _saving = true);
    final error = await widget.onSubmit(_input.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(_input.text);
    } else {
      setState(() {
        _error = error;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: widget.fieldKey,
        controller: _input,
        autofocus: true,
        keyboardType: widget.numeric
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : TextInputType.text,
        decoration: InputDecoration(
          errorText: _error,
          labelText: widget.fieldLabel,
        ),
        onSubmitted: _saving ? null : (_) => unawaited(_submit()),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }
}
