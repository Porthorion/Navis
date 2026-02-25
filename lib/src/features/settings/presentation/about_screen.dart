import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:url_launcher/url_launcher.dart';

/// Displays app version, open-source licenses, and repository links.
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  /// True while the user has explicitly triggered an update check so we know
  /// whether to show the "up to date" snackbar when the result arrives.
  bool _userTriggeredCheck = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final updateAsync = ref.watch(updateProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final settings = settingsAsync.asData?.value;
    final packageInfo = ref.watch(packageInfoProvider).asData?.value;
    final version = packageInfo?.version ?? '';

    // Show a snackbar when a user-triggered check resolves as up to date,
    // or auto-show the update dialog when an update is found.
    ref.listen<AsyncValue<UpdateInfo?>>(updateProvider, (prev, next) {
      if (!mounted || !_userTriggeredCheck) return;
      if (next.isLoading) return;
      setState(() => _userTriggeredCheck = false);
      final info = next.asData?.value;
      if (!next.hasError && info == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.updateUpToDate)),
        );
      } else if (info != null && info.apkDownloadUrl != null) {
        showUpdateDialog(context, info);
      }
    });

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: ListView(
        children: <Widget>[
          const SizedBox(height: 24),
          const Center(child: NavisIcon(size: 112, tintWithAccent: true)),
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
            '${l10n.aboutVersion} $version',
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
                applicationVersion: version,
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
              final uri = Uri.parse(AppConstants.repoUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              l10n.updatesSettingsSectionLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.system_update_outlined),
            title: Text(l10n.updateAutoCheckTitle),
            subtitle: Text(l10n.updateAutoCheckSubtitle),
            value: settings?.updateCheckEnabled ?? true,
            onChanged: (value) {
              if (settings == null) return;
              final repo = ref.read(settingsRepositoryProvider);
              repo.saveSettings(settings.copyWith(updateCheckEnabled: value));
            },
          ),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: Text(l10n.updateCheckTitle),
            subtitle: Text(
              updateAsync.when(
                data: (UpdateInfo? info) => info != null
                    ? l10n.updateAvailableBody(info.tagName)
                    : l10n.updateUpToDate,
                loading: () => l10n.updateCheckSub(version),
                error: (_, _) => l10n.updateCheckSub(version),
              ),
            ),
            trailing: updateAsync.isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : updateAsync.asData?.value != null
                    ? FilledButton.icon(
                        onPressed: () {
                          final info = updateAsync.asData!.value!;
                          if (info.apkDownloadUrl != null) {
                            showUpdateDialog(context, info);
                          } else {
                            launchUrl(
                              Uri.parse(info.htmlUrl),
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        },
                        icon: const Icon(Icons.install_mobile, size: 18),
                        label: Text(l10n.updateInstall),
                      )
                    : const Icon(Icons.refresh),
            onTap: () {
                setState(() => _userTriggeredCheck = true);
                ref.invalidate(updateProvider);
              },
          ),
        ],
      ),
    );
  }

}
