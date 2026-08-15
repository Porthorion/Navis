import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/routing/desktop_layout.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final sections = <_PrivacySectionData>[
      _PrivacySectionData(
        title: l10n.privacyAccountsTitle,
        body: l10n.privacyAccountsBody,
      ),
      _PrivacySectionData(
        title: l10n.privacyScrobblingTitle,
        body: l10n.privacyScrobblingBody,
      ),
      _PrivacySectionData(
        title: l10n.privacyDownloadsTitle,
        body: l10n.privacyDownloadsBody,
      ),
      _PrivacySectionData(
        title: l10n.privacyDiagnosticsTitle,
        body: l10n.privacyDiagnosticsBody,
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l10n.privacyTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final useTwoColumns = desktopMode && constraints.maxWidth >= 900;
          final horizontalPadding = desktopMode ? 24.0 : 16.0;
          final availableWidth =
              constraints.maxWidth - horizontalPadding * 2 - 32;
          return ListView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              desktopMode ? 24 : 12,
              horizontalPadding,
              32,
            ),
            children: <Widget>[
              if (useTwoColumns)
                Wrap(
                  spacing: 32,
                  runSpacing: 4,
                  children: [
                    for (final section in sections)
                      SizedBox(
                        width: availableWidth / 2,
                        child: _PrivacySection(
                          title: section.title,
                          body: section.body,
                        ),
                      ),
                  ],
                )
              else
                for (final section in sections)
                  _PrivacySection(title: section.title, body: section.body),
              const Divider(height: 32),
              Text(
                l10n.privacySummary,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PrivacySectionData {
  const _PrivacySectionData({required this.title, required this.body});

  final String title;
  final String body;
}

class _PrivacySection extends StatelessWidget {
  const _PrivacySection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(body, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
