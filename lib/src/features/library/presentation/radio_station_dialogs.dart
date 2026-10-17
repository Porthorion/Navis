import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Opens the add/edit dialog. New stations stay on this device unless an
/// admin switches "Save on Server" on (only offered while the server's radio
/// list is available). The same switch moves an [existing] device station to
/// the server; [isLocal] says where it lives. Server stations never move back.
Future<void> showRadioStationEditor(
  BuildContext context,
  WidgetRef ref, {
  InternetRadioStation? existing,
  bool isLocal = true,
}) {
  final canChooseServer =
      (existing == null || isLocal) &&
      ref.read(serverUserIsAdminProvider).asData?.value == true &&
      ref.read(radioStationsProvider).hasValue;
  return showDialog<void>(
    context: context,
    builder: (_) => _RadioStationEditor(
      existing: existing,
      isLocal: isLocal,
      canChooseServer: canChooseServer,
    ),
  );
}

/// Asks before deleting [station]; failures are reported on [context].
Future<void> showRadioStationDelete(
  BuildContext context,
  WidgetRef ref,
  InternetRadioStation station, {
  required bool isLocal,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final theme = Theme.of(context);
  final homepage = station.homePageUrl;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.radioDeleteTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(station.name, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(station.streamUrl, style: theme.textTheme.bodySmall),
          if (homepage != null && homepage.isNotEmpty)
            Text(homepage, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          Text(
            isLocal ? l10n.radioDeleteScopeDevice : l10n.radioDeleteScopeServer,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.commonDelete),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await ref
        .read(radioStationActionsProvider)
        .delete(station, isLocal: isLocal);
  } on Object {
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: l10n.radioDeleteFailed,
      level: AppNoticeLevel.error,
    );
  }
}

class _RadioStationEditor extends ConsumerStatefulWidget {
  const new({
    required this.existing,
    required this.isLocal,
    required this.canChooseServer,
  });

  final InternetRadioStation? existing;
  final bool isLocal;
  final bool canChooseServer;

  @override
  ConsumerState<_RadioStationEditor> createState() =>
      _RadioStationEditorState();
}

class _RadioStationEditorState extends ConsumerState<_RadioStationEditor> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _streamUrl = TextEditingController(
    text: widget.existing?.streamUrl,
  );
  late final _homepage = TextEditingController(
    text: widget.existing?.homePageUrl,
  );
  var _toServer = false;
  var _saving = false;
  var _saveFailed = false;
  String? _nameError;
  String? _streamUrlError;
  String? _homepageError;

  @override
  void dispose() {
    _name.dispose();
    _streamUrl.dispose();
    _homepage.dispose();
    super.dispose();
  }

  void _clearSaveError(String value) {
    if (_saveFailed) setState(() => _saveFailed = false);
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _saving = true;
      _saveFailed = false;
      _nameError = _streamUrlError = _homepageError = null;
    });
    try {
      await ref
          .read(radioStationActionsProvider)
          .save(
            existing: widget.existing,
            isLocal: widget.existing == null ? !_toServer : widget.isLocal,
            moveToServer:
                widget.existing != null && widget.isLocal && _toServer,
            name: _name.text,
            streamUrl: _streamUrl.text,
            homePageUrl: _homepage.text,
          );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (!mounted) return;
      // Validation failures come back as ArgumentErrors naming the field.
      final field = error is ArgumentError ? error.name : null;
      setState(() {
        _saving = false;
        switch (field) {
          case 'name':
            _nameError = l10n.radioEditorNameError;
          case 'streamUrl':
            _streamUrlError = l10n.radioEditorUrlError;
          case 'homePageUrl':
            _homepageError = l10n.radioEditorUrlError;
          default:
            _saveFailed = true;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(
        widget.existing == null ? l10n.radioAddStation : l10n.radioEditStation,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey<String>('radioEditorName'),
              controller: _name,
              onChanged: _clearSaveError,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.radioEditorNameLabel,
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey<String>('radioEditorStreamUrl'),
              controller: _streamUrl,
              onChanged: _clearSaveError,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.radioEditorStreamUrlLabel,
                errorText: _streamUrlError,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey<String>('radioEditorHomepage'),
              controller: _homepage,
              onChanged: _clearSaveError,
              keyboardType: TextInputType.url,
              onSubmitted: _saving ? null : (_) => _submit(),
              decoration: InputDecoration(
                labelText: l10n.radioEditorHomepageLabel,
                errorText: _homepageError,
              ),
            ),
            if (widget.canChooseServer)
              SwitchListTile(
                key: const ValueKey<String>('radioEditorSaveToServer'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.radioEditorSaveToServer),
                subtitle: Text(l10n.radioEditorSaveToServerHint),
                value: _toServer,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        _toServer = value;
                        _saveFailed = false;
                      }),
              ),
            if (_saveFailed) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.radioEditorSaveFailed)),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          key: const ValueKey<String>('radioEditorSave'),
          onPressed: _saving ? null : _submit,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
