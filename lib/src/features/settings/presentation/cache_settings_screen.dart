import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/providers/app_providers.dart';

class CacheSettingsScreen extends ConsumerStatefulWidget {
  const CacheSettingsScreen({super.key});

  @override
  ConsumerState<CacheSettingsScreen> createState() =>
      _CacheSettingsScreenState();
}

class _CacheSettingsScreenState extends ConsumerState<CacheSettingsScreen> {
  /// Slider value in megabytes. null = not yet loaded from DB.
  int? _budgetMb;

  /// True while a clear operation is in progress.
  bool _clearing = false;

  static const int _minBudgetMb = 500;
  static const int _maxBudgetMb = 10240; // 10 GB
  static const int _stepMb = 500;

  @override
  void initState() {
    super.initState();
    _loadCurrentBudget();
  }

  Future<void> _loadCurrentBudget() async {
    final dao = ref.read(navisDatabaseProvider).appSettingsDao;
    final mb = await dao.getRollingCacheBudgetMb();
    if (mounted) {
      setState(() => _budgetMb = mb);
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
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.cacheSettingsBudgetSaved)));
    }
  }

  Future<void> _clearRollingCache() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.cacheSettingsClearRolling),
        content: Text(l10n.cacheSettingsClearRollingConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancelAction),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
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

  Future<void> _clearPermanentCache() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.cacheSettingsClearPermanent),
        content: Text(l10n.cacheSettingsClearPermanentConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancelAction),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.cacheSettingsClearPermanent),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      await _clearCacheByType(CacheType.permanent);
      if (mounted) _showClearedSnackBar();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _clearCoverArtCache() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.cacheSettingsClearCoverArt),
        content: Text(l10n.cacheSettingsClearCoverArtConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancelAction),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.cacheSettingsClearCoverArt),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      await DefaultCacheManager().emptyCache();
      if (mounted) _showClearedSnackBar();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _clearCacheByType(CacheType type) async {
    final db = ref.read(navisDatabaseProvider);
    final cacheDao = db.cacheDao;

    // Fetch tracks of the given type.
    final tracks = await cacheDao.getCachedTracks();
    final filtered = tracks.where((t) => t.cacheType == type).toList();

    // Delete files.
    for (final track in filtered) {
      final paths = <String>[
        track.filePath,
        '${track.filePath}.part',
        '${track.filePath}.mime',
      ];
      for (final path in paths) {
        final file = File(path);
        if (file.existsSync()) {
          try {
            file.deleteSync();
          } on FileSystemException {
            // best-effort
          }
        }
      }
    }

    // Remove DB rows.
    if (filtered.isNotEmpty) {
      await cacheDao
          .deleteCachedTracksBySongIds(filtered.map((t) => t.songId));
    }
  }

  void _showClearedSnackBar() {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(l10n.cacheSettingsClearSuccess)));
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
  }

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
    final permanentStats = ref.watch(permanentCacheStatsProvider);
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
                    formatBytes: _formatBytes,
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
                        Text(l10n.cacheSettingsRollingBudgetLabel),
                        const Spacer(),
                        Text(
                          _budgetLabel(_budgetMb!, l10n),
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
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

                // ---- Permanent / downloaded tracks section ----
                _SectionHeader(title: l10n.cacheSettingsPermanentSection),
                permanentStats.when(
                  data: (stats) => _CacheStatsCard(
                    usedBytes: stats.totalBytes,
                    budgetBytes: null,
                    trackCount: stats.trackCount,
                    formatBytes: _formatBytes,
                    l10n: l10n,
                    isRolling: false,
                  ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => const SizedBox.shrink(),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(l10n.cacheSettingsClearPermanent),
                  onTap: _clearPermanentCache,
                ),
                const Divider(),

                // ---- Cover art cache ----
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: Text(l10n.cacheSettingsClearCoverArt),
                  onTap: _clearCoverArtCache,
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
    final budgetLabel =
        budgetBytes != null ? formatBytes(budgetBytes!) : null;
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
