import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/data/update_install_mode.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:url_launcher/url_launcher.dart';

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

enum _DownloadPhase {
  confirm,
  downloading,
  done,
  applying,
  noWriteAccess,
  signatureMismatch,
  error,
}

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
  // True when the error occurred while *applying* the downloaded artifact
  // (as opposed to during the download itself). Used to tailor the error UI.
  bool _isApplyError = false;
  String? _apkPath;
  CancelToken? _cancelToken;
  late final UpdateInstallMode _installMode;

  @override
  void initState() {
    super.initState();
    _installMode = detectInstallMode();
  }

  @override
  void dispose() {
    _cancelToken?.cancel('Dialog dismissed');
    super.dispose();
  }

  Future<void> _startDownload() async {
    // On desktop, check write access before downloading.
    if (isDesktopInstallMode(_installMode) &&
        !_service.canApplyUpdate(_installMode)) {
      setState(() => _phase = _DownloadPhase.noWriteAccess);
      return;
    }

    setState(() {
      _phase = _DownloadPhase.downloading;
      _progress = 0;
      _error = null;
      _isApplyError = false;
    });

    _cancelToken = CancelToken();

    try {
      final path = await _service.downloadArtifact(
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

      // On Android, immediately trigger the system installer.
      if (Platform.isAndroid) {
        await _service.installApk(path);
      }
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
    } on PlatformException catch (e) {
      // installApk() throws PlatformException for Android install errors such
      // as a signing-key mismatch (installed and downloaded APKs signed with
      // different keys — user must uninstall first).
      AppLogger.error('APK install failed', e);
      if (mounted) {
        final isSignatureMismatch =
            e.code == 'INSTALL_ERROR' &&
            (e.message ?? '').toLowerCase().contains('signature');
        setState(() {
          if (isSignatureMismatch) {
            _phase = _DownloadPhase.signatureMismatch;
          } else {
            _phase = _DownloadPhase.error;
            _error = e.message ?? e.code;
          }
        });
      }
    } on Object catch (e) {
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
                  child: MarkdownBody(
                    data: widget.info.releaseNotes!,
                    styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                      p: theme.textTheme.bodySmall,
                    ),
                    shrinkWrap: true,
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
            Expanded(
              child: Text(
                isDesktopInstallMode(_installMode)
                    ? l10n.updateReadyToRestart
                    : l10n.updateReadyToInstall,
              ),
            ),
          ],
        );

      case _DownloadPhase.applying:
        return Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(l10n.updateApplying)),
          ],
        );

      case _DownloadPhase.noWriteAccess:
        return Row(
          children: [
            Icon(Icons.lock_outline, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.updateNoWriteAccess)),
          ],
        );

      case _DownloadPhase.signatureMismatch:
        return Row(
          children: [
            Icon(
              Icons.security_update_warning,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.updateSignatureMismatch)),
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
                Expanded(
                  child: Text(
                    _isApplyError
                        ? l10n.updateApplyFailed
                        : l10n.updateDownloadFailed,
                  ),
                ),
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
        if (isDesktopInstallMode(_installMode)) {
          return [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.updateDismiss),
            ),
            FilledButton.icon(
              onPressed: () async {
                if (_apkPath == null) return;
                setState(() => _phase = _DownloadPhase.applying);
                try {
                  await _service.applyDesktopUpdate(_apkPath!, _installMode);
                } on Object catch (e) {
                  AppLogger.error('Failed to apply desktop update', e);
                  if (mounted) {
                    setState(() {
                      _isApplyError = true;
                      _phase = _DownloadPhase.error;
                      _error = e.toString();
                    });
                  }
                }
              },
              icon: const Icon(Icons.restart_alt),
              label: Text(l10n.updateRestartAndUpdate),
            ),
          ];
        }
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

      case _DownloadPhase.applying:
        return const [];

      case _DownloadPhase.noWriteAccess:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.updateDismiss),
          ),
          FilledButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(widget.info.htmlUrl),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new),
            label: Text(l10n.updateDownloadManually),
          ),
        ];

      case _DownloadPhase.signatureMismatch:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.updateDismiss),
          ),
          FilledButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(widget.info.htmlUrl),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new),
            label: Text(l10n.updateDownloadManually),
          ),
        ];

      case _DownloadPhase.error:
        return [
          TextButton(
            onPressed: () => launchUrl(
              Uri.parse(widget.info.htmlUrl),
              mode: LaunchMode.externalApplication,
            ),
            child: Text(l10n.updateDownloadManually),
          ),
          if (!_isApplyError)
            FilledButton(
              onPressed: _startDownload,
              child: Text(l10n.updateRetry),
            ),
        ];
    }
  }
}
