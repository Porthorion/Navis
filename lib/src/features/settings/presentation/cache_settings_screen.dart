import 'dart:io';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/format_utils.dart';
import 'package:path_provider/path_provider.dart';

class CacheSettingsScreen extends ConsumerStatefulWidget {
  const CacheSettingsScreen({super.key});

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
    _loadCurrentBudget();
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
      final tempDir = await getTemporaryDirectory();
      final dir = Directory('${tempDir.path}/$coverArtCacheKey');
      if (!dir.existsSync()) {
        if (mounted) setState(() => _coverArtStorageBytes = 0);
        return;
      }
      var total = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } on FileSystemException {
            // skip
          }
        }
      }
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
    await cacheManager.enforceBudget(maxBytes: mb * 1024 * 1024);

    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      AppNoticeMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.cacheSettingsBudgetSaved)));
    }
  }

  Future<void> _saveCoverArtMax(int maxObjects) async {
    final dao = ref.read(navisDatabaseProvider).appSettingsDao;
    await dao.updateCoverArtCacheMaxObjects(maxObjects);
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      AppNoticeMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.cacheSettingsCoverArtMaxSaved)),
        );
    }
  }

  Future<void> _clearRollingCache() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.cacheSettingsClearRolling),
        content: Text(l10n.cacheSettingsClearRollingConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.cacheSettingsClearRolling),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.cacheSettingsClearCoverArt),
        content: Text(l10n.cacheSettingsClearCoverArtConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.cacheSettingsClearCoverArt),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      await defaultCoverArtCacheManager.emptyCache();
      if (mounted) {
        setState(() => _coverArtStorageBytes = 0);
        _showClearedSnackBar();
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _repairLibraryCache() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Repair Library Cache'),
        content: const Text(
          'This will clear streaming cache, downloaded tracks, cover art cache, '
          'and local library metadata, then force a full library resync. '
          'This action cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Repair Library Cache'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      final db = ref.read(navisDatabaseProvider);

      await _clearCacheByType(CacheType.rolling);
      await _clearCacheByType(CacheType.permanent);

      await defaultCoverArtCacheManager.emptyCache();
      await db.libraryDao.clearLibraryData();

      final syncState = await ref
          .read(librarySyncControllerProvider.notifier)
          .syncNow(forceFull: true);

      if (!mounted) return;
      setState(() => _coverArtStorageBytes = 0);

      final messenger = AppNoticeMessenger.of(context)..clearSnackBars();
      if (syncState.status == LibrarySyncStatus.succeeded ||
          syncState.status == LibrarySyncStatus.skipped) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Library cache repaired and full resync completed.'),
          ),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              syncState.errorMessage == null ||
                      syncState.errorMessage!.trim().isEmpty
                  ? 'Cache was cleared, but full resync failed.'
                  : 'Cache was cleared, but full resync failed: '
                        '${syncState.errorMessage}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  Future<void> _clearCacheByType(CacheType type) async {
    final db = ref.read(navisDatabaseProvider);
    final cacheDao = db.cacheDao;

    // Fetch only tracks of the given type (avoids loading all tracks).
    final filtered = await cacheDao.watchCachedTracksByType(type).first;

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
    AppNoticeMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(l10n.cacheSettingsClearSuccess)));
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
        await defaultCoverArtCacheManager.downloadFile(url, key: '$id:300');
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
      AppNoticeMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.cacheSettingsPrecacheSuccess(done)),
          ),
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
    final rollingStats = ref.watch(rollingCacheStatsProvider);
    final budgetBytes = ref.watch(rollingCacheBudgetBytesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.cacheSettingsTitle)),
      body: _clearing
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: <Widget>[
                // ---- Rolling cache section ----
                _SectionHeader(title: l10n.cacheSettingsRollingSection),
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
                              style: Theme.of(context).textTheme.bodyMedium
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
                _SectionHeader(title: l10n.cacheSettingsCoverArtSection),
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
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
                      divisions: (_maxCoverArt - _minCoverArt) ~/ _stepCoverArt,
                      label: l10n.cacheSettingsCoverArtMaxValue(_coverArtMax!),
                      onChanged: (value) {
                        setState(() => _coverArtMax = value.round());
                      },
                      onChangeEnd: (value) => _saveCoverArtMax(value.round()),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      l10n.cacheSettingsCoverArtRestart,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                    leading: const Icon(Icons.download_for_offline_outlined),
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
                ListTile(
                  leading: const Icon(Icons.build_circle_outlined),
                  title: const Text('Repair Library Cache'),
                  subtitle: const Text(
                    'Clear all caches and force a full metadata resync.',
                  ),
                  onTap: _repairLibraryCache,
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable widgets
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _CacheStatsCard extends StatelessWidget {
  const _CacheStatsCard({
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
              borderRadius: BorderRadius.circular(4),
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
