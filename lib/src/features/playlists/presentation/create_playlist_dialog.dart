import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Asks for a name and where to keep the playlist, then creates it with
/// [songIds]. The outcome is shown as a notice on [context].
Future<void> showCreatePlaylistDialog(
  BuildContext context,
  WidgetRef ref, {
  List<String> songIds = const <String>[],
}) async {
  final actions = ref.read(playlistActionsProvider);
  final l10n = AppLocalizations.of(context)!;
  final choice = await showDialog<({String name, bool onServer})>(
    context: context,
    builder: (_) => const _CreatePlaylistDialog(),
  );
  if (choice == null) return;
  try {
    await actions.create(choice.name, songIds, onServer: choice.onServer);
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: l10n.playlistsCreateSuccess,
      level: AppNoticeLevel.success,
    );
  } on Object catch (error) {
    AppLogger.warning('Playlist creation failed: $error');
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: l10n.playlistsCreateFailed,
      level: AppNoticeLevel.error,
    );
  }
}

class _CreatePlaylistDialog extends ConsumerStatefulWidget {
  const new();

  @override
  ConsumerState<_CreatePlaylistDialog> createState() =>
      _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends ConsumerState<_CreatePlaylistDialog> {
  final _controller = TextEditingController();

  /// The switch before the saved setting has caught up with a tap.
  bool? _tapped;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _available => ref.read(playlistServerCreationAvailableProvider);

  bool get _onServer =>
      _available && (_tapped ?? ref.read(playlistCreateOnServerProvider));

  Future<void> _save(bool enabled) async {
    try {
      await ref
          .read(playlistCreateOnServerProvider.notifier)
          .setOnServer(enabled: enabled);
    } on Object catch (error) {
      AppLogger.warning('Saving the playlist destination failed: $error');
    }
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name: name, onServer: _onServer));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final available = ref.watch(playlistServerCreationAvailableProvider);
    final saved = ref.watch(playlistCreateOnServerProvider);
    return AlertDialog(
      title: Text(l10n.playlistsCreateTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.playlistsCreateNameLabel,
            ),
            onSubmitted: (_) => _submit(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.playlistsSaveToServerLabel),
            subtitle: Text(
              available
                  ? l10n.playlistsSaveToServerSubtitle
                  : l10n.playlistsSaveToServerOfflineSubtitle,
            ),
            value: available && (_tapped ?? saved),
            onChanged: available
                ? (enabled) {
                    setState(() => _tapped = enabled);
                    unawaited(_save(enabled));
                  }
                : null,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.playlistsCreateAction),
        ),
      ],
    );
  }
}
