import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/database/daos/network_usage_dao.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:navis/src/utils/format_utils.dart';

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
                tooltip: l10n.syncSettingsBackToSettings,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => NavService.returnToSettings(context, ref),
              )
            : null,
        title: Text(l10n.aboutTitle),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: desktopMode ? 24 : 0),
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
              _buildDataUsageSection(context),
              const SizedBox(height: 12),
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
                leading: const Icon(Icons.history_outlined),
                title: Text(l10n.aboutChangelog),
                subtitle: Text(l10n.aboutChangelogSub),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/about/changelog'),
              ),
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: Text(l10n.privacyTitle),
                subtitle: Text(l10n.privacySub),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/about/privacy'),
              ),
              if (showUpdateControls) ...<Widget>[
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
                    repo.saveSettings(
                      settings.copyWith(updateCheckEnabled: value),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: Text(l10n.updateCheckTitle),
                  subtitle: Text(
                    updateAsync.when(
                      data: (info) => info != null
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
                            unawaited(_handleUpdateAction(context, ref, info));
                          },
                          icon: Icon(
                            updateAsync.asData!.value!.delivery ==
                                    UpdateDelivery.storeRedirect
                                ? Icons.shop_2_outlined
                                : Icons.install_mobile,
                            size: 18,
                          ),
                          label: Text(
                            updateAsync.asData!.value!.delivery ==
                                    UpdateDelivery.storeRedirect
                                ? l10n.updateOpenPlayStore
                                : l10n.updateInstall,
                          ),
                        )
                      : const Icon(Icons.refresh),
                  onTap: () {
                    setState(() => _userTriggeredCheck = true);
                    ref
                        .read(updateForceCheckProvider.notifier)
                        .requestForceCheck();
                    ref.invalidate(updateProvider);
                  },
                ),
              ],
            ],
          ),
        ),
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
      await showUpdateDialog(
        context,
        info,
        updateService: updateService,
      );
      return;
    }

    await launchUrl(
      Uri.parse(info.htmlUrl),
      mode: LaunchMode.externalApplication,
    );
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
                  ListTile(
                    title: Text(l10n.aboutDataUsageEmpty),
                    dense: true,
                  ),
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
              ListTile(
                dense: true,
                title: LinearProgressIndicator(),
              ),
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
    if (confirmed != true || !mounted) {
      return;
    }

    try {
      await ref.read(networkUsageMeterProvider).clearAll();
      if (!mounted) return;
      showAppNotice(
        context,
        message: l10n.aboutDataUsageResetComplete,
        level: AppNoticeLevel.info,
      );
    } on Object {
      if (!mounted) return;
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
