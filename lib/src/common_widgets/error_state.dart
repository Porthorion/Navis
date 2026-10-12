import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

class ErrorState extends StatelessWidget {
  const new({
    required this.title,
    super.key,
    this.message,
    this.onRetry,
    this.retryLabel,
    this.retryKey,
    this.secondaryAction,
  });

  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String? retryLabel;
  final Key? retryKey;

  /// An alternative to Retry (for example a search), shown beneath it.
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Back-end exceptions can disclose implementation details and rarely tell
    // someone what to do. Error-state callers retain a purpose-specific title
    // and Retry; a short recovery hint supplies the missing next step.
    final displayedMessage =
        message ?? (onRetry == null ? null : l10n.commonErrorRecoveryHint);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 36),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (displayedMessage != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                displayedMessage,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton.tonal(
                key: retryKey,
                style: NavisColorStyleData.tonalStyleOf(context),
                onPressed: onRetry,
                child: Text(retryLabel ?? l10n.commonRetry),
              ),
            ],
            if (secondaryAction != null) ...<Widget>[
              const SizedBox(height: 8),
              secondaryAction!,
            ],
          ],
        ),
      ),
    );
  }
}
