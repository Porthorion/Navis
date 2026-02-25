import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Shows a dialog that downloads an APK update and triggers the system
/// installer when the download completes.
///
/// Call [showUpdateDialog] to display this from anywhere in the widget tree.
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDownloadDialog(info: info),
  );
}

// ---------------------------------------------------------------------------

enum _DownloadPhase { confirm, downloading, done, error }

class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({required this.info});
  final UpdateInfo info;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  final _service = UpdateService();
  _DownloadPhase _phase = _DownloadPhase.confirm;
  double _progress = 0;
  String? _error;
  String? _apkPath;
  CancelToken? _cancelToken;

  @override
  void dispose() {
    _cancelToken?.cancel('Dialog dismissed');
    super.dispose();
  }

  Future<void> _startDownload() async {
    setState(() {
      _phase = _DownloadPhase.downloading;
      _progress = 0;
      _error = null;
    });

    _cancelToken = CancelToken();

    try {
      final path = await _service.downloadApk(
        widget.info,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        cancelToken: _cancelToken,
      );

      if (!mounted) return;

      setState(() {
        _phase = _DownloadPhase.done;
        _apkPath = path;
      });

      // Immediately trigger install.
      await _service.installApk(path);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        // User cancelled — just close.
        return;
      }
      AppLogger.error('Update download failed', e);
      if (mounted) {
        setState(() {
          _phase = _DownloadPhase.error;
          _error = e.message;
        });
      }
    } on Exception catch (e) {
      AppLogger.error('Update download failed', e);
      if (mounted) {
        setState(() {
          _phase = _DownloadPhase.error;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(l10n.updateAvailableTitle),
      content: _buildContent(l10n, theme),
      actions: _buildActions(l10n),
    );
  }

  Widget _buildContent(AppLocalizations l10n, ThemeData theme) {
    switch (_phase) {
      case _DownloadPhase.confirm:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.updateAvailableBody(widget.info.tagName)),
            if (widget.info.releaseNotes != null &&
                widget.info.releaseNotes!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                l10n.updateReleaseNotes,
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Text(
                    widget.info.releaseNotes!,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ],
        );

      case _DownloadPhase.downloading:
        final percent = (_progress * 100).toInt();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.updateDownloading(widget.info.tagName)),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text('$percent%', style: Theme.of(context).textTheme.bodySmall),
          ],
        );

      case _DownloadPhase.done:
        return Row(
          children: [
            Icon(Icons.check_circle, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.updateReadyToInstall)),
          ],
        );

      case _DownloadPhase.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: theme.colorScheme.error),
                const SizedBox(width: 12),
                Expanded(child: Text(l10n.updateDownloadFailed)),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        );
    }
  }

  List<Widget> _buildActions(AppLocalizations l10n) {
    switch (_phase) {
      case _DownloadPhase.confirm:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.updateDismiss),
          ),
          FilledButton.icon(
            onPressed: _startDownload,
            icon: const Icon(Icons.download),
            label: Text(l10n.updateInstall),
          ),
        ];

      case _DownloadPhase.downloading:
        return [
          TextButton(
            onPressed: () {
              _cancelToken?.cancel('User cancelled');
              Navigator.of(context).pop();
            },
            child: Text(l10n.cancelAction),
          ),
        ];

      case _DownloadPhase.done:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.updateDismiss),
          ),
          FilledButton.icon(
            onPressed: () async {
              if (_apkPath != null) {
                await _service.installApk(_apkPath!);
              }
            },
            icon: const Icon(Icons.install_mobile),
            label: Text(l10n.updateInstall),
          ),
        ];

      case _DownloadPhase.error:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.updateDismiss),
          ),
          FilledButton(
            onPressed: _startDownload,
            child: Text(l10n.updateRetry),
          ),
        ];
    }
  }
}
