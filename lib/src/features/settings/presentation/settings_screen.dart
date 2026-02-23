import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(l10n.settingsServerTitle),
            subtitle: Text(l10n.settingsServerSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/server'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: Text(l10n.settingsCacheTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/cache'),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.downloadsTitle),
            subtitle: Text(l10n.settingsDownloadsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/downloads'),
          ),
          ListTile(
            leading: const Icon(Icons.sync_outlined),
            title: Text(l10n.settingsSyncTitle),
            subtitle: Text(l10n.settingsSyncSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/sync'),
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq_outlined),
            title: Text(l10n.settingsPlaybackTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/playback'),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(l10n.settingsAppearanceTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/appearance'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.aboutTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/about'),
          ),
        ],
      ),
    );
  }
}
