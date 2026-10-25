import 'dart:async';

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/confirm_dialog.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_controller.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/utils/format_utils.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart'
    show coverArtCacheStorageBytes;
import 'package:navis/src/routing/app_routes.dart';

class CacheSettingsScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<CacheSettingsScreen> createState() =>
      _CacheSettingsScreenState();
}

class _CacheSettingsScreenState extends ConsumerState<CacheSettingsScreen> {
  /// Slider value in megabytes. null = not yet loaded from DB.
  int? _budgetMb;

  /// Cover art cache max objects. null = not yet loaded.
  int? _coverArtMax;

  /// True while a clear operation is in progress.
  bool _clearing = false;

  // Cover art storage size in bytes. null = not yet calculated.
  int? _coverArtStorageBytes;

  // Pre-cache state
  bool _isCaching = false;
  int _cachingProgress = 0;
  int _cachingTotal = 0;

  static const int _minBudgetMb = 500;
  static const int _maxBudgetMb = 10240; // 10 GB
  static const int _stepMb = 500;

  static const int _minCoverArt = 500;
  static const int _maxCoverArt = 20000;
  static const int _stepCoverArt = 500;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCurrentBudget());
  }

  Future<void> _loadCurrentBudget() async {
    final dao = ref.read(navisDatabaseProvider).appSettingsDao;
    final mb = await dao.getRollingCacheBudgetMb();
    final coverArt = await dao.getCoverArtCacheMaxObjects();
    if (mounted) {
      setState(() {
        _budgetMb = mb;
        _coverArtMax = coverArt;
      });
    }
    await _loadCoverArtStorageBytes();
  }

  Future<void> _loadCoverArtStorageBytes() async {
    try {
      final total = await coverArtCacheStorageBytes();
      if (mounted) setState(() => _coverArtStorageBytes = total);
    } on Exception {
      if (mounted) setState(() => _coverArtStorageBytes = 0);
    }
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _saveBudget(int mb) async {
    final dao = ref.read(navisDatabaseProvider).appSettingsDao;
    await dao.updateRollingCacheBudgetMb(mb);

    // If the user lowered the budget, enforce immediately.
    final cacheManager = ref.read(rollingCacheManagerProvider);
    await cacheManager.enforceBudget(
      maxBytes: mb * 1024 * 1024,
      keepSongIds:
          ref.read(audioHandlerProvider)?.rollingCacheProtectedSongIds ??
          const <String>{},
    );

    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      AppNoticeMessenger.of(context).clearSnackBars();
      showAppNotice(
        context,
        message: l10n.cacheSettingsBudgetSaved,
        level: AppNoticeLevel.success,
      );
    }
  }

  Future<void> _saveCoverArtMax(int maxObjects) async {
    final dao = ref.read(navisDatabaseProvider).appSettingsDao;
    await dao.updateCoverArtCacheMaxObjects(maxObjects);
    // Invalidate so the next access creates a fresh CacheManager with the new
    // limit. Safe here because the manager has been running since startup and
    // its SQLite DB is fully initialized.
    ref.invalidate(coverArtCacheManagerProvider);
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      AppNoticeMessenger.of(context).clearSnackBars();
      showAppNotice(
        context,
        message: l10n.cacheSettingsCoverArtMaxSaved,
        level: AppNoticeLevel.success,
      );
    }
  }

  Future<void> _clearRollingCache() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showConfirmDialog(
      context,
      title: l10n.cacheSettingsClearRolling,
      message: l10n.cacheSettingsClearRollingConfirm,
      confirmLabel: l10n.cacheSettingsClearRolling,
      destructive: true,
    );
    if (!confirm || !mounted) return;

    setState(() => _clearing = true);
    try {
      await _clearCacheByType(CacheType.rolling);
      if (mounted) _showClearedSnackBar();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _clearCoverArtCache() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showConfirmDialog(
      context,
      title: l10n.cacheSettingsClearCoverArt,
      message: l10n.cacheSettingsClearCoverArtConfirm,
      confirmLabel: l10n.cacheSettingsClearCoverArt,
      destructive: true,
    );
    if (!confirm || !mounted) return;

    setState(() => _clearing = true);
    try {
      await ref.read(clearCoverArtCachesProvider)();
      if (mounted) {
        setState(() => _coverArtStorageBytes = 0);
        _showClearedSnackBar();
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _deleteAllPresets() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showConfirmDialog(
      context,
      title: l10n.cacheSettingsDeleteAllPresetsConfirmTitle,
      message: l10n.cacheSettingsDeleteAllPresetsConfirmBody,
      confirmLabel: l10n.cacheSettingsDeleteAllPresets,
      destructive: true,
    );
    if (!confirm || !mounted) return;
    setState(() => _clearing = true);
    try {
      await ref
          .read(appearanceLooksControllerProvider.notifier)
          .deleteAllPresets();
      if (mounted) {
        showAppNotice(
          context,
          message: l10n.cacheSettingsDeleteAllPresetsSuccess,
          level: AppNoticeLevel.success,
        );
      }
    } on Object {
      if (mounted) {
        showAppNotice(
          context,
          message: l10n.cacheSettingsDeleteAllPresetsFailure,
          level: AppNoticeLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _resetLibraryCache() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showConfirmDialog(
      context,
      title: l10n.cacheSettingsResetLibraryCacheConfirmTitle,
      message: l10n.cacheSettingsResetLibraryCacheConfirmBody,
      confirmLabel: l10n.cacheSettingsResetLibraryCacheConfirmAction,
      destructive: true,
    );
    if (!confirm || !mounted) return;

    var allowMeteredBroadOverride = false;
    if (ref.read(syncNetworkPolicyProvider).isMetered) {
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.cacheSettingsResetLibraryCacheMeteredConfirmTitle,
        message: l10n.cacheSettingsResetLibraryCacheMeteredConfirmBody,
        confirmLabel: l10n.cacheSettingsResetLibraryCacheMeteredConfirmAction,
      );
      if (!confirmed || !mounted) return;
      allowMeteredBroadOverride = true;
    }

    if (!mounted) return;
    context.go(
      requiredLibraryRebuildRoute(
        RequiredLibraryRebuildReason.manualCacheReset,
        allowMeteredBroadOverride: allowMeteredBroadOverride,
      ),
    );
  }

  Future<void> _clearCacheByType(CacheType type) async {
    final db = ref.read(navisDatabaseProvider);
    final cacheDao = db.cacheDao;

    // Fetch only tracks of the given type (avoids loading all tracks).
    final filtered = await cacheDao.watchCachedTracksByType(type).first;

    if (type == CacheType.permanent) {
      await ref
          .read(downloadServiceProvider)
          .removeDownloadedTracks(filtered.map((track) => track.songId));
      return;
    }

    // Delete files.
    for (final track in filtered) {
      for (final suffix in <String>['', '.part', '.mime']) {
        try {
          final file = File('${track.filePath}$suffix');
          if (file.existsSync()) file.deleteSync();
        } on FileSystemException {
          // best-effort
        }
      }
    }

    // Remove DB rows.
    if (filtered.isNotEmpty) {
      await cacheDao.deleteCachedTracksBySongIds(filtered.map((t) => t.songId));
    }
  }

  void _showClearedSnackBar() {
    final l10n = AppLocalizations.of(context)!;
    AppNoticeMessenger.of(context).clearSnackBars();
    showAppNotice(
      context,
      message: l10n.cacheSettingsClearSuccess,
      level: AppNoticeLevel.success,
    );
  }

  // ---------------------------------------------------------------------------
  // Pre-cache cover art
  // ---------------------------------------------------------------------------

  Future<void> _preCacheAllCoverArt() async {
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    final l10n = AppLocalizations.of(context)!;
    final albums = await ref
        .read(navisDatabaseProvider)
        .libraryDao
        .getAllAlbums();

    final coverArtIds = albums
        .where((a) => a.coverArt != null && a.coverArt!.isNotEmpty)
        .map((a) => a.coverArt!)
        .toSet()
        .toList(growable: false);

    if (coverArtIds.isEmpty) return;

    setState(() {
      _isCaching = true;
      _cachingProgress = 0;
      _cachingTotal = coverArtIds.length;
    });

    var done = 0;
    for (final id in coverArtIds) {
      if (!mounted) break;
      try {
        final url = api.getCoverArtUrl(id: id, size: 300).toString();
        await ref
            .read(coverArtCacheManagerProvider)
            .downloadFile(url, key: coverArtImageCacheKey(id, 300));
      } on Exception {
        // best-effort: skip failures
      }
      done++;
      if (mounted) setState(() => _cachingProgress = done);
    }

    if (mounted) {
      setState(() => _isCaching = false);
      // Refresh storage size display
      await _loadCoverArtStorageBytes();
      if (!mounted) return;
      AppNoticeMessenger.of(context).clearSnackBars();
      showAppNotice(
        context,
        message: l10n.cacheSettingsPrecacheSuccess(done),
        level: AppNoticeLevel.success,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _budgetLabel(int mb, AppLocalizations l10n) {
    final gb = mb / 1024;
    return l10n.cacheSettingsBudgetGb(gb.toStringAsFixed(1));
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final rollingStats = ref.watch(rollingCacheStatsProvider);
    final rollingActivity = ref.watch(rollingCacheActivityProvider);
    final budgetBytes = ref.watch(rollingCacheBudgetBytesProvider);

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
        title: Text(l10n.cacheSettingsTitle),
      ),
      body: _clearing
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(l10n.cacheSettingsClearing),
                ],
              ),
            )
          : Theme(
              data: desktopMode
                  ? Theme.of(context).copyWith(
                      cardTheme: const CardThemeData(
                        color: Colors.transparent,
                        elevation: 0,
                        margin: EdgeInsets.zero,
                        shadowColor: Colors.transparent,
                        surfaceTintColor: Colors.transparent,
                        shape: RoundedRectangleBorder(),
                      ),
                    )
                  : Theme.of(context),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      desktopMode ? 8 : 0,
                      desktopMode ? 8 : 0,
                      desktopMode ? 8 : 0,
                      16,
                    ),
                    children: <Widget>[
                      // ---- Rolling cache section ----
                      NavisSectionHeader(
                        title: l10n.cacheSettingsRollingSection,
                        compact: true,
                        maxLines: null,
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          16,
                          16,
                          16,
                          4,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          l10n.cacheSettingsRollingDescription,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                      rollingStats.when(
                        data: (stats) => _CacheStatsCard(
                          usedBytes: stats.totalBytes,
                          budgetBytes: budgetBytes,
                          trackCount: stats.trackCount,
                          formatBytes: formatBytes,
                          l10n: l10n,
                          isRolling: true,
                        ),
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => const SizedBox.shrink(),
                      ),
                      if (rollingActivity.isCaching)
                        _RollingCacheActivity(activity: rollingActivity),
                      // Budget slider
                      if (_budgetMb != null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  l10n.cacheSettingsRollingBudgetLabel,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    _budgetLabel(_budgetMb!, l10n),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Slider(
                          value: _budgetMb!.toDouble(),
                          min: _minBudgetMb.toDouble(),
                          max: _maxBudgetMb.toDouble(),
                          divisions: (_maxBudgetMb - _minBudgetMb) ~/ _stepMb,
                          label: _budgetLabel(_budgetMb!, l10n),
                          onChanged: (value) {
                            setState(() => _budgetMb = value.round());
                          },
                          onChangeEnd: (value) => _saveBudget(value.round()),
                        ),
                      ],
                      ListTile(
                        leading: const Icon(Icons.delete_outline),
                        title: Text(l10n.cacheSettingsClearRolling),
                        onTap: _clearRollingCache,
                      ),
                      const Divider(),

                      // ---- Cover art cache ----
                      NavisSectionHeader(
                        title: l10n.cacheSettingsCoverArtSection,
                        compact: true,
                        maxLines: null,
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          16,
                          16,
                          16,
                          4,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          l10n.cacheSettingsCoverArtDescription,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (_coverArtStorageBytes != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                          child: Text(
                            l10n.cacheSettingsCoverArtSizeLabel(
                              formatBytes(_coverArtStorageBytes!),
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      if (_coverArtMax != null) ...[
                        SwitchListTile(
                          value: _coverArtMax == 0,
                          onChanged: (unlimited) async {
                            final newMax = unlimited ? 0 : _minCoverArt;
                            setState(() => _coverArtMax = newMax);
                            await _saveCoverArtMax(newMax);
                          },
                          title: Text(l10n.cacheSettingsCoverArtUnlimitedLabel),
                          subtitle: Text(
                            l10n.cacheSettingsCoverArtUnlimitedSubtitle,
                          ),
                        ),
                        if (_coverArtMax! > 0) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    l10n.cacheSettingsCoverArtMaxLabel,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      l10n.cacheSettingsCoverArtMaxValue(
                                        _coverArtMax!,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.end,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Slider(
                            value: _coverArtMax!.toDouble(),
                            min: _minCoverArt.toDouble(),
                            max: _maxCoverArt.toDouble(),
                            divisions:
                                (_maxCoverArt - _minCoverArt) ~/ _stepCoverArt,
                            label: l10n.cacheSettingsCoverArtMaxValue(
                              _coverArtMax!,
                            ),
                            onChanged: (value) {
                              setState(() => _coverArtMax = value.round());
                            },
                            onChangeEnd: (value) =>
                                _saveCoverArtMax(value.round()),
                          ),
                        ],
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            l10n.cacheSettingsCoverArtRestart,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                      if (_isCaching)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.cacheSettingsPrecachingProgress(
                                  _cachingProgress,
                                  _cachingTotal,
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: _cachingTotal > 0
                                    ? _cachingProgress / _cachingTotal
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      if (_coverArtMax == 0 && !_isCaching)
                        ListTile(
                          leading: const Icon(
                            Icons.download_for_offline_outlined,
                          ),
                          title: Text(l10n.cacheSettingsPrecacheTitle),
                          subtitle: Text(l10n.cacheSettingsPrecacheSubtitle),
                          onTap: _preCacheAllCoverArt,
                        ),
                      ListTile(
                        leading: const Icon(Icons.image_outlined),
                        title: Text(l10n.cacheSettingsClearCoverArt),
                        onTap: _clearCoverArtCache,
                      ),
                      const Divider(),
                      NavisSectionHeader(
                        title: l10n.cacheSettingsResetSection,
                        compact: true,
                        maxLines: null,
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          16,
                          16,
                          16,
                          4,
                        ),
                      ),
                      ListTile(
                        key: const ValueKey('deleteAllPresets'),
                        leading: const Icon(Icons.delete_outline),
                        title: Text(l10n.cacheSettingsDeleteAllPresets),
                        subtitle: Text(
                          l10n.cacheSettingsDeleteAllPresetsDescription,
                        ),
                        onTap: _clearing ? null : _deleteAllPresets,
                      ),
                      ListTile(
                        leading: const Icon(Icons.build_circle_outlined),
                        title: Text(l10n.cacheSettingsResetLibraryCache),
                        subtitle: Text(
                          l10n.cacheSettingsResetLibraryCacheDescription,
                        ),
                        onTap: _clearing ? null : _resetLibraryCache,
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _RollingCacheActivity extends StatelessWidget {
  const new({required this.activity});

  final RollingCacheActivity activity;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final progress = activity.progress;
    final hasProgress = progress != null && progress > 0 && progress < 1;
    final percent = ((progress ?? 0) * 100).round().clamp(0, 100);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: hasProgress ? progress : null,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            hasProgress
                ? l10n.cacheSettingsRollingCachingProgress(percent)
                : l10n.cacheSettingsRollingCaching,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable widgets
// ---------------------------------------------------------------------------

class _CacheStatsCard extends StatelessWidget {
  const new({
    required this.usedBytes,
    required this.budgetBytes,
    required this.trackCount,
    required this.formatBytes,
    required this.l10n,
    required this.isRolling,
  });

  final int usedBytes;
  final int? budgetBytes;
  final int trackCount;
  final String Function(int) formatBytes;
  final AppLocalizations l10n;
  final bool isRolling;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usedLabel = formatBytes(usedBytes);
    final budgetLabel = budgetBytes != null ? formatBytes(budgetBytes!) : null;
    final progress = budgetBytes != null && budgetBytes! > 0
        ? (usedBytes / budgetBytes!).clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (budgetLabel != null)
            Text(
              l10n.cacheSettingsRollingCurrentSize(usedLabel, budgetLabel),
              style: theme.textTheme.bodyMedium,
            )
          else
            Text(usedLabel, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          if (budgetBytes != null)
            ClipRRect(
              borderRadius: NavisShapeData.of(context).xsAll,
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          const SizedBox(height: 4),
          Text(
            isRolling
                ? l10n.cacheSettingsRollingTrackCount(trackCount)
                : l10n.cacheSettingsPermanentTrackCount(trackCount),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
