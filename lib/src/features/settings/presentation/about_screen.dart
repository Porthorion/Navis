import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/database/daos/network_usage_dao.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:navis/src/utils/format_utils.dart';

import 'package:navis/src/utils/external_url.dart';
import 'package:navis/src/routing/app_routes.dart';

/// Displays app version, open-source licenses, and repository links.
class AboutScreen extends ConsumerStatefulWidget {
  const new({super.key});

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
    final updateAsync = ref.watch(updateProvider);
    // "Check now" is the user's own request, so only the master and updates
    // service switches block it; the automatic check has its own switch in
    // Integrations.
    final checksAllowed = ref.watch(
      integrationPolicyProvider.select(
        (policy) => policy.isServiceEnabled(IntegrationService.updates),
      ),
    );
    final packageInfo = ref.watch(packageInfoProvider).asData?.value;
    final version = packageInfo?.version ?? '';
    final showUpdateControls =
        !kIsWeb && defaultTargetPlatform != TargetPlatform.iOS;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    // Show a snackbar when a user-triggered check resolves as up to date,
    // or auto-show the update dialog when an update is found.
    ref.listen<AsyncValue<UpdateInfo?>>(updateProvider, (prev, next) {
      if (!mounted || !_userTriggeredCheck) return;
      if (next.isLoading) return;
      setState(() => _userTriggeredCheck = false);
      final info = next.asData?.value;
      if (!next.hasError && info == null) {
        showAppNotice(
          context,
          message: l10n.updateUpToDate,
          level: AppNoticeLevel.info,
        );
      } else if (info != null) {
        unawaited(
          showUpdateDialog(
            context,
            info,
            updateService: ref.read(updateServiceProvider),
          ),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !desktopMode,
        leading: desktopMode
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    NavService.back(context, fallback: AppRoutes.settings),
              )
            : null,
        title: Text(l10n.aboutTitle),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final useDesktopColumns = desktopMode && constraints.maxWidth >= 1100;
          final identity = _AboutIdentity(
            version: version,
            alignStart: useDesktopColumns,
          );
          final information = _AboutInformation(
            onShowLicenses: () {
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
          );
          final updates = _AboutUpdates(
            visible: showUpdateControls,
            checksAllowed: checksAllowed,
            update: updateAsync,
            version: version,
            onCheckNow: () {
              setState(() => _userTriggeredCheck = true);
              ref.read(updateForceCheckProvider.notifier).requestForceCheck();
              ref.invalidate(updateProvider);
            },
            onInstall: updateAsync.asData?.value == null
                ? null
                : () => unawaited(
                    _handleUpdateAction(
                      context,
                      ref,
                      updateAsync.asData!.value!,
                    ),
                  ),
          );

          return ListView(
            padding: EdgeInsets.fromLTRB(
              desktopMode ? 24 : 0,
              24,
              desktopMode ? 24 : 0,
              24,
            ),
            children: <Widget>[
              if (useDesktopColumns)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          identity,
                          const SizedBox(height: 24),
                          _buildDataUsageSection(context),
                        ],
                      ),
                    ),
                    const SizedBox(width: 40),
                    Expanded(
                      flex: 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[information, updates],
                      ),
                    ),
                  ],
                )
              else ...<Widget>[
                identity,
                const SizedBox(height: 24),
                _buildDataUsageSection(context),
                const SizedBox(height: 12),
                information,
                updates,
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _handleUpdateAction(
    BuildContext context,
    WidgetRef ref,
    UpdateInfo info,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final updateService = ref.read(updateServiceProvider);
    if (info.delivery == UpdateDelivery.storeRedirect) {
      final launched = await updateService.openPlayStoreListing(
        fallbackUrl: info.htmlUrl,
      );
      if (!context.mounted) {
        return;
      }
      if (!launched) {
        showAppNotice(
          context,
          message: l10n.updatePlayStoreFallbackNotice,
          level: AppNoticeLevel.info,
        );
      }
      return;
    }

    if (info.downloadUrl != null) {
      await showUpdateDialog(context, info, updateService: updateService);
      return;
    }

    await launchExternalHttpUrl(info.htmlUrl);
  }

  Widget _buildDataUsageSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final today = ref.watch(networkUsageTotalProvider(1));
    final sevenDays = ref.watch(networkUsageTotalProvider(7));
    final thirtyDays = ref.watch(networkUsageTotalProvider(30));
    final categoryTotals = ref.watch(networkUsageCategoryTotalsProvider(7));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            l10n.aboutDataUsageTitle,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.aboutDataUsageSubtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.today_outlined),
          title: Text(l10n.aboutDataUsageToday),
          subtitle: Text(_formatUsageRequests(l10n, today)),
          trailing: Text(_formatUsageBytes(today)),
        ),
        ListTile(
          leading: const Icon(Icons.calendar_view_week_outlined),
          title: Text(l10n.aboutDataUsageSevenDays),
          subtitle: Text(_formatUsageRequests(l10n, sevenDays)),
          trailing: Text(_formatUsageBytes(sevenDays)),
        ),
        ListTile(
          leading: const Icon(Icons.calendar_month_outlined),
          title: Text(l10n.aboutDataUsageThirtyDays),
          subtitle: Text(_formatUsageRequests(l10n, thirtyDays)),
          trailing: Text(_formatUsageBytes(thirtyDays)),
        ),
        ExpansionTile(
          leading: const Icon(Icons.stacked_bar_chart_outlined),
          title: Text(l10n.aboutDataUsageBreakdown),
          children: categoryTotals.when(
            data: (totals) {
              if (totals.isEmpty) {
                return <Widget>[
                  ListTile(title: Text(l10n.aboutDataUsageEmpty), dense: true),
                ];
              }
              return totals
                  .map(
                    (total) => ListTile(
                      dense: true,
                      title: Text(_categoryLabel(l10n, total.category)),
                      subtitle: Text(
                        '${_networkTypeLabel(l10n, total.networkType)} - '
                        '${l10n.aboutDataUsageRequests(total.requestCount)}',
                      ),
                      trailing: Text(formatBytes(total.bytes)),
                    ),
                  )
                  .toList(growable: false);
            },
            loading: () => const <Widget>[
              ListTile(dense: true, title: LinearProgressIndicator()),
            ],
            error: (_, _) => <Widget>[
              ListTile(
                dense: true,
                title: Text(l10n.aboutDataUsageUnavailable),
              ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.restart_alt_outlined),
          title: Text(l10n.aboutDataUsageReset),
          onTap: () => _confirmResetUsageStats(context),
        ),
      ],
    );
  }

  String _formatUsageBytes(AsyncValue<NetworkUsageTotal> value) {
    return value.when(
      data: (total) => formatBytes(total.bytes),
      loading: () => '...',
      error: (_, _) => '--',
    );
  }

  String _formatUsageRequests(
    AppLocalizations l10n,
    AsyncValue<NetworkUsageTotal> value,
  ) {
    return value.when(
      data: (total) => l10n.aboutDataUsageRequests(total.requestCount),
      loading: () => l10n.aboutDataUsageLoading,
      error: (_, _) => l10n.aboutDataUsageUnavailable,
    );
  }

  Future<void> _confirmResetUsageStats(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.aboutDataUsageResetConfirmTitle),
        content: Text(l10n.aboutDataUsageResetConfirmMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.aboutDataUsageResetCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.aboutDataUsageResetConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !context.mounted) {
      return;
    }

    try {
      await ref.read(networkUsageMeterProvider).clearAll();
      if (!mounted || !context.mounted) return;
      showAppNotice(
        context,
        message: l10n.aboutDataUsageResetComplete,
        level: AppNoticeLevel.info,
      );
    } on Object {
      if (!mounted || !context.mounted) return;
      showAppNotice(
        context,
        message: l10n.aboutDataUsageResetFailed,
        level: AppNoticeLevel.error,
      );
    }
  }

  String _categoryLabel(AppLocalizations l10n, String category) {
    if (category == NetworkUsageCategory.audioStream.key) {
      return l10n.aboutDataUsageCategoryAudioStreaming;
    }
    if (category == NetworkUsageCategory.download.key) {
      return l10n.aboutDataUsageCategoryDownloads;
    }
    if (category == NetworkUsageCategory.coverArt.key) {
      return l10n.aboutDataUsageCategoryCoverArt;
    }
    if (category == NetworkUsageCategory.librarySync.key) {
      return l10n.aboutDataUsageCategoryLibrarySync;
    }
    if (category == NetworkUsageCategory.lyrics.key) {
      return l10n.aboutDataUsageCategoryLyrics;
    }
    if (category == NetworkUsageCategory.scrobble.key) {
      return l10n.aboutDataUsageCategoryScrobbling;
    }
    if (category == NetworkUsageCategory.recommendations.key) {
      return l10n.aboutDataUsageCategoryRecommendations;
    }
    if (category == NetworkUsageCategory.updates.key) {
      return l10n.aboutDataUsageCategoryUpdates;
    }
    return l10n.aboutDataUsageCategoryOtherApi;
  }

  String _networkTypeLabel(AppLocalizations l10n, String networkType) {
    return switch (networkType) {
      'wifi' => l10n.aboutDataUsageNetworkWifi,
      'cellular' => l10n.aboutDataUsageNetworkMobile,
      'offline' => l10n.aboutDataUsageNetworkOffline,
      _ => l10n.aboutDataUsageNetworkOther,
    };
  }
}

class _AboutIdentity extends StatelessWidget {
  const new({required this.version, required this.alignStart});

  final String version;
  final bool alignStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Text('Navis', style: theme.textTheme.headlineMedium);
    final versionLabel = Text(
      '${AppLocalizations.of(context)!.aboutVersion} $version',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    if (alignStart) {
      return Row(
        children: <Widget>[
          const NavisIcon(size: 96, tintWithAccent: true),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[title, const SizedBox(height: 4), versionLabel],
          ),
        ],
      );
    }

    return Align(
      alignment: Alignment.center,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const NavisIcon(size: 112, tintWithAccent: true),
          const SizedBox(height: 12),
          title,
          const SizedBox(height: 4),
          versionLabel,
        ],
      ),
    );
  }
}

class _AboutInformation extends ConsumerWidget {
  const new({required this.onShowLicenses});

  final VoidCallback onShowLicenses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: <Widget>[
        const Divider(),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(l10n.aboutLicenses),
          subtitle: Text(l10n.aboutLicensesSub),
          trailing: const Icon(Icons.chevron_right),
          onTap: onShowLicenses,
        ),
        ListTile(
          leading: const Icon(Icons.history_outlined),
          title: Text(l10n.aboutChangelog),
          subtitle: Text(l10n.aboutChangelogSub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => NavService.openChangelog(context),
        ),
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: Text(l10n.privacyTitle),
          subtitle: Text(l10n.privacySub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => NavService.openPrivacy(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.hub_outlined),
          title: Text(l10n.integrationsTitle),
          subtitle: Text(l10n.integrationsSubtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => NavService.openSettingsPage(
            context,
            ref,
            SettingsPage.integrations,
          ),
        ),
      ],
    );
  }
}

class _AboutUpdates extends StatelessWidget {
  const new({
    required this.visible,
    required this.checksAllowed,
    required this.update,
    required this.version,
    required this.onCheckNow,
    required this.onInstall,
  });

  final bool visible;

  /// False while Online services or update checks are off in Integrations.
  final bool checksAllowed;
  final AsyncValue<UpdateInfo?> update;
  final String version;
  final VoidCallback onCheckNow;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final updateInfo = update.asData?.value;
    return Column(
      children: <Widget>[
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.updatesSettingsSectionLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        ListTile(
          enabled: checksAllowed,
          leading: const Icon(Icons.system_update_outlined),
          title: Text(l10n.updateCheckTitle),
          subtitle: Text(
            !checksAllowed
                ? l10n.updateCheckOffInIntegrations
                : update.when(
                    data: (info) => info != null
                        ? l10n.updateAvailableBody(info.tagName)
                        : l10n.updateUpToDate,
                    loading: () => l10n.updateCheckSub(version),
                    error: (_, _) => l10n.updateCheckSub(version),
                  ),
          ),
          trailing: update.isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : updateInfo != null
              ? FilledButton.icon(
                  onPressed: onInstall,
                  icon: Icon(
                    updateInfo.delivery == UpdateDelivery.storeRedirect
                        ? Icons.shop_2_outlined
                        : Icons.install_mobile,
                    size: 18,
                  ),
                  label: Text(
                    updateInfo.delivery == UpdateDelivery.storeRedirect
                        ? l10n.updateOpenPlayStore
                        : l10n.updateInstall,
                  ),
                )
              : const Icon(Icons.refresh),
          onTap: onCheckNow,
        ),
      ],
    );
  }
}
