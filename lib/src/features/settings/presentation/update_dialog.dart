import 'package:dio/dio.dart';
import 'package:flutter/material.dart' as legacy;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/settings/data/update_install_mode.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows a dialog that downloads and applies an update, or redirects to a store.
///
/// Call [showUpdateDialog] to display this from anywhere in the widget tree.
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info, {
  required UpdateService updateService,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _UpdateDownloadDialog(info: info, updateService: updateService),
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
  const new({required this.info, required this.updateService});
  final UpdateInfo info;
  final UpdateService updateService;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  late final UpdateService _service;
  _DownloadPhase _phase = _DownloadPhase.confirm;
  double _progress = 0;
  // True when the error occurred while *applying* the downloaded artifact
  // (as opposed to during the download itself). Used to tailor the error UI.
  bool _isApplyError = false;
  bool _isIntegrityError = false;
  String? _apkPath;
  CancelToken? _cancelToken;
  late final UpdateInstallMode _installMode;

  @override
  void initState() {
    super.initState();
    _service = widget.updateService;
    _installMode = detectInstallMode();
  }

  @override
  void dispose() {
    _cancelToken?.cancel('Dialog dismissed');
    super.dispose();
  }

  bool get _isStoreRedirect =>
      widget.info.delivery == UpdateDelivery.storeRedirect;

  bool get _isSelfUpdate => widget.info.delivery == UpdateDelivery.selfUpdate;

  Future<void> _openPlayStore() async {
    final launched = await _service.openPlayStoreListing(
      fallbackUrl: widget.info.htmlUrl,
    );
    if (!mounted) {
      return;
    }
    if (!launched) {
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!.updatePlayStoreFallbackNotice,
        level: AppNoticeLevel.info,
      );
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _startDownload() async {
    if (_isStoreRedirect) {
      await _openPlayStore();
      return;
    }

    // On desktop, check write access before downloading.
    if (isDesktopInstallMode(_installMode) &&
        !_service.canApplyUpdate(_installMode)) {
      setState(() => _phase = _DownloadPhase.noWriteAccess);
      return;
    }

    setState(() {
      _phase = _DownloadPhase.downloading;
      _progress = 0;
      _isApplyError = false;
      _isIntegrityError = false;
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

      if (_isSelfUpdate) {
        await _service.installApk(path);
      }
    } on UpdateIntegrityException catch (e) {
      AppLogger.error('Update integrity verification failed', e);
      if (mounted) {
        setState(() {
          _isIntegrityError = true;
          _phase = _DownloadPhase.error;
        });
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
        });
      }
    } on PlatformException catch (e) {
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
          }
        });
      }
    } on Object catch (e) {
      AppLogger.error('Update download failed', e);
      if (mounted) {
        setState(() {
          _phase = _DownloadPhase.error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(
        _isStoreRedirect
            ? l10n.updatePlayStoreTitle
            : l10n.updateAvailableTitle,
      ),
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
            Text(
              _isStoreRedirect
                  ? l10n.updatePlayStoreBody(widget.info.tagName)
                  : l10n.updateAvailableBody(widget.info.tagName),
            ),
            if (widget.info.releaseNotes != null &&
                widget.info.releaseNotes!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l10n.updateReleaseNotes, style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  // flutter_markdown_plus still consumes legacy ThemeData.
                  // Remove this bridge when its Material migration is released.
                  // ignore: deprecated_member_use
                  child: MaterialUiCompatibilityBridge(
                    child: Builder(
                      builder: (context) => MarkdownBody(
                        data: widget.info.releaseNotes!,
                        styleSheet: MarkdownStyleSheet.fromTheme(
                          legacy.Theme.of(context),
                        ).copyWith(p: theme.textTheme.bodySmall),
                        shrinkWrap: true,
                      ),
                    ),
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
            Icon(Icons.security_update_warning, color: theme.colorScheme.error),
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
                    _isIntegrityError
                        ? l10n.updateDownloadDamaged
                        : _isApplyError
                        ? l10n.updateApplyFailed
                        : l10n.updateDownloadFailed,
                  ),
                ),
              ],
            ),
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
            icon: Icon(
              _isStoreRedirect ? Icons.shop_2_outlined : Icons.download,
            ),
            label: Text(
              _isStoreRedirect ? l10n.updateOpenPlayStore : l10n.updateInstall,
            ),
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
                    });
                  }
                }
              },
              icon: const Icon(Icons.restart_alt),
              label: Text(l10n.updateRestartAndUpdate),
            ),
          ];
        }
        if (_isSelfUpdate) {
          return [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.updateDismiss),
            ),
            FilledButton.icon(
              onPressed: () async {
                if (_apkPath == null) return;
                try {
                  await _service.installApk(_apkPath!);
                } on PlatformException catch (e) {
                  AppLogger.error('APK install failed', e);
                  if (!mounted) return;
                  final isSignatureMismatch =
                      e.code == 'INSTALL_ERROR' &&
                      (e.message ?? '').toLowerCase().contains('signature');
                  setState(() {
                    if (isSignatureMismatch) {
                      _phase = _DownloadPhase.signatureMismatch;
                    } else {
                      _phase = _DownloadPhase.error;
                    }
                  });
                }
              },
              icon: const Icon(Icons.install_mobile),
              label: Text(l10n.updateInstall),
            ),
          ];
        }
        return [];

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
