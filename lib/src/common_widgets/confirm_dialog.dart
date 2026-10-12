import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';

/// Shows a Cancel / confirm [AlertDialog]; resolves `true` only when the
/// confirm button is pressed. [destructive] paints the confirm button with the
/// error colours. [cancelLabel] defaults to the shared "Cancel" string.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  bool destructive = false,
  Key? confirmKey,
  String? cancelLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(
            cancelLabel ?? AppLocalizations.of(dialogContext)!.cancelAction,
          ),
        ),
        FilledButton(
          key: confirmKey,
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  foregroundColor: Theme.of(dialogContext).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// The "Remove download" confirmation shared by song, album and downloads UI.
Future<bool> confirmRemoveDownload(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showConfirmDialog(
    context,
    title: l10n.downloadsRemoveConfirmTitle,
    message: l10n.downloadsRemoveConfirmContent,
    confirmLabel: l10n.downloadsRemoveAction,
    destructive: true,
  );
}
