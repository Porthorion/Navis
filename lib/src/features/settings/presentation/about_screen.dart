import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:url_launcher/url_launcher.dart';

/// Displays app version, open-source licenses, and repository links.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String _repoUrl = 'https://git.porthorion.com/khalifa/Navis';
  static const String _version = 'Cape Horn 0.1';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: ListView(
        children: <Widget>[
          const SizedBox(height: 24),
          const Center(child: NavisIcon(size: 72, tintWithAccent: true)),
          const SizedBox(height: 12),
          Text(
            'Navis',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${l10n.aboutVersion} $_version',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(l10n.aboutLicenses),
            subtitle: Text(l10n.aboutLicensesSub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              showLicensePage(
                context: context,
                applicationName: 'Navis',
                applicationVersion: _version,
                applicationIcon: const Padding(
                  padding: EdgeInsets.all(8),
                  child: NavisIcon(size: 48, tintWithAccent: true),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(l10n.aboutSourceCode),
            subtitle: Text(l10n.aboutSourceCodeSub),
            trailing: const Icon(Icons.open_in_new),
            onTap: () async {
              final uri = Uri.parse(_repoUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
      ),
    );
  }
}
