import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:navis/l10n/app_localizations.dart';

/// A modal dialog used on Linux and Windows as a substitute for the system
/// share sheet (which does not support file sharing on those platforms).
///
/// Displays the generated share-card image alongside the share text and
/// offers a "Copy Link" button.
class ShareDesktopDialog extends StatelessWidget {
  const ShareDesktopDialog({
    super.key,
    required this.cardBytes,
    required this.shareText,
  });

  final Uint8List cardBytes;
  final String shareText;

  static Future<void> show(
    BuildContext context, {
    required Uint8List cardBytes,
    required String shareText,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => ShareDesktopDialog(
        cardBytes: cardBytes,
        shareText: shareText,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Card image preview
            AspectRatio(
              aspectRatio: 1200 / 630,
              child: Image.memory(cardBytes, fit: BoxFit.cover),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Share link text
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      shareText,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(l10n.closeAction),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        label: Text(l10n.copyLinkAction),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: shareText),
                          );
                          if (context.mounted) {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
