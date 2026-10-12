import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/confirm_dialog.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_provider.dart';

Future<void> showPlaybackRecoverySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _PlaybackRecoverySheet(),
  );
}

class _PlaybackRecoverySheet extends ConsumerStatefulWidget {
  const new();

  @override
  ConsumerState<_PlaybackRecoverySheet> createState() =>
      _PlaybackRecoverySheetState();
}

class _PlaybackRecoverySheetState
    extends ConsumerState<_PlaybackRecoverySheet> {
  bool _busy = false;
  String? _error;

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final confirmed = await showConfirmDialog(
      context,
      title: title,
      message: body,
      confirmLabel: action,
      destructive: true,
    );
    return confirmed;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on Object {
      if (mounted) {
        setState(
          () =>
              _error = AppLocalizations.of(context)!
                  .playbackRecoveryActionFailed,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final recovery = ref.read(playbackRecoveryServiceProvider);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              l10n.playbackRecoverySheetTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(l10n.playbackRecoverySheetSubtitle),
            const SizedBox(height: 20),
            if (_busy)
              const Center(child: CircularProgressIndicator())
            else ...<Widget>[
              FilledButton(
                onPressed: () {
                  recovery.retryPlayback();
                  Navigator.of(context).pop();
                },
                child: Text(l10n.playbackRecoveryRetry),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () async {
                  if (!await _confirm(
                    title: l10n.playbackRecoveryResetConfirmTitle,
                    body: l10n.playbackRecoveryResetConfirmBody,
                    action: l10n.playbackRecoveryResetConfirmAction,
                  )) {
                    return;
                  }
                  await _run(recovery.resetLibraryCacheAndRetry);
                },
                child: Text(l10n.playbackRecoveryResetCache),
              ),
              TextButton(
                onPressed: () =>
                    _run(() => recovery.signOut(wipeLocalData: false)),
                child: Text(l10n.serverSettingsSignOutKeepData),
              ),
              TextButton(
                onPressed: () async {
                  if (!await _confirm(
                    title: l10n.playbackRecoveryWipeConfirmTitle,
                    body: l10n.playbackRecoveryWipeConfirmBody,
                    action: l10n.playbackRecoveryWipeConfirmAction,
                  )) {
                    return;
                  }
                  await _run(() => recovery.signOut(wipeLocalData: true));
                },
                child: Text(l10n.serverSettingsSignOutWipeData),
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
