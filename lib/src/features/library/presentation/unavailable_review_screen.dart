import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/confirm_dialog.dart';
import 'package:navis/src/common_widgets/navis_modal_sheet.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/song_id_utils.dart';

/// Pending review rows plus the saved song rows behind them (album names live
/// on `songs`, which keeps tombstoned rows), read in one batched query.
class UnavailableReviewData {
  const new(this.rows, this.songs, [this.likedParents = const <String>{}]);

  final List<LibraryRecoveryReviewTableData> rows;
  final Map<String, SongsTableData> songs;

  /// `type:id` of the album and artist rows that carry a like.
  final Set<String> likedParents;
}

/// Review entries for items that identity recovery could not relink.
final unavailableReviewProvider = StreamProvider.autoDispose
    .family<UnavailableReviewData, int>((ref, serverId) {
      final database = ref.watch(navisDatabaseProvider);
      return database.librarySyncDao
          .watchPendingRecoveryReview(serverId)
          .asyncMap((rows) async {
            final songs = await database.libraryDao.getSongsByIds([
              for (final row in rows)
                if (row.entityType == 'song') row.oldId,
            ]);
            List<String> idsOf(String type) => [
              for (final row in rows)
                if (row.entityType == type) row.oldId,
            ];
            return UnavailableReviewData(
              rows,
              {for (final song in songs) song.id: song},
              {
                for (final album in await database.libraryDao.getAlbumsByIds(
                  idsOf('album'),
                ))
                  if (album.starred != null) 'album:${album.id}',
                for (final artist in await database.libraryDao.getArtistsByIds(
                  idsOf('artist'),
                ))
                  if (artist.starred != null) 'artist:${artist.id}',
              },
            );
          });
    });

/// Live count of rows awaiting review for the signed-in server.
final pendingUnavailableCountProvider = StreamProvider.autoDispose<int>((ref) {
  final serverId = ref.watch(serverConfigStateProvider).asData?.value?.id;
  if (serverId == null) {
    return Stream.value(0);
  }
  return ref
      .watch(navisDatabaseProvider)
      .librarySyncDao
      .watchPendingRecoveryReviewCount(serverId);
});

/// References an identity remap carries over, assembled from the same tables
/// the remap transaction touches so the preview never promises more than the
/// apply actually moves.
class _ReferenceSummary {
  const new({
    this.copies = 0,
    this.playlistEntries = 0,
    this.history = 0,
    this.queueEntries = 0,
    this.pendingAnnotations = 0,
    this.followingSongs = 0,
  });

  final int copies;
  final int playlistEntries;
  final int history;
  final int queueEntries;
  final int pendingAnnotations;
  final int followingSongs;

  bool get isEmpty =>
      copies == 0 &&
      playlistEntries == 0 &&
      history == 0 &&
      queueEntries == 0 &&
      pendingAnnotations == 0 &&
      followingSongs == 0;
}

Future<_ReferenceSummary> _collectReferences(
  NavisDatabase database,
  LibraryRecoveryReviewTableData entry,
) async {
  Future<int> count(String sql, String oldId) async {
    final row = await database
        .customSelect(
          sql,
          variables: <Variable<Object>>[Variable<String>(oldId)],
        )
        .getSingle();
    return row.read<int>('amount');
  }

  switch (entry.entityType) {
    case 'album':
      return _ReferenceSummary(
        followingSongs: await count(
          'SELECT COUNT(*) AS amount FROM songs WHERE album_id = ?;',
          entry.oldId,
        ),
        pendingAnnotations: await count(
          'SELECT COUNT(*) AS amount FROM star_sync_queue '
          "WHERE item_type = 'album' AND item_id = ?;",
          entry.oldId,
        ),
      );
    case 'artist':
      final songs = await count(
        'SELECT COUNT(*) AS amount FROM songs WHERE artist_id = ?;',
        entry.oldId,
      );
      final albums = await count(
        'SELECT COUNT(*) AS amount FROM albums WHERE artist_id = ?;',
        entry.oldId,
      );
      return _ReferenceSummary(
        followingSongs: songs + albums,
        pendingAnnotations: await count(
          'SELECT COUNT(*) AS amount FROM star_sync_queue '
          "WHERE item_type = 'artist' AND item_id = ?;",
          entry.oldId,
        ),
      );
    default:
      return _ReferenceSummary(
        copies: await count(
          'SELECT COUNT(*) AS amount FROM cached_tracks '
          "WHERE song_id = ? AND download_status = 'complete';",
          entry.oldId,
        ),
        playlistEntries: await count(
          'SELECT COUNT(*) AS amount FROM playlist_songs WHERE song_id = ?;',
          entry.oldId,
        ),
        history: await count(
          'SELECT COUNT(*) AS amount FROM play_history WHERE song_id = ?;',
          entry.oldId,
        ),
        queueEntries: await count(
          'SELECT COUNT(*) AS amount FROM play_queue_items WHERE song_id = ?;',
          entry.oldId,
        ),
        pendingAnnotations: await count(
          'SELECT COUNT(*) AS amount FROM star_sync_queue '
          "WHERE item_type = 'song' AND item_id = ?;",
          entry.oldId,
        ),
      );
  }
}

class UnavailableReviewScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<UnavailableReviewScreen> createState() =>
      _UnavailableReviewScreenState();
}

/// A song that cannot be un-liked from here: a remote catalog copy.
bool _isRemoteRow(LibraryRecoveryReviewTableData row, SongsTableData? song) =>
    isRemoteSong(id: row.oldId, isExternal: song?.isExternal);

/// Rows Remove from Liked (single and bulk) covers: liked songs that are not
/// remote copies, and liked albums and artists.
bool _isRemovableLike(
  UnavailableReviewData data,
  LibraryRecoveryReviewTableData row,
) {
  if (row.entityType != 'song') {
    return data.likedParents.contains('${row.entityType}:${row.oldId}');
  }
  final song = data.songs[row.oldId];
  return song?.starred != null && !_isRemoteRow(row, song);
}

class _AlbumGroup {
  _AlbumGroup(this.title, this.artist);

  final String title;
  final String artist;
  final List<LibraryRecoveryReviewTableData> rows = [];
}

class _UnavailableReviewScreenState
    extends ConsumerState<UnavailableReviewScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final serverId = ref.watch(serverConfigStateProvider).asData?.value?.id;
    final data = serverId == null
        ? const AsyncValue<UnavailableReviewData>.data(
            UnavailableReviewData([], {}),
          )
        : ref.watch(unavailableReviewProvider(serverId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.unavailableReviewTitle)),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text(l10n.unavailableReviewLoadError)),
        data: (data) {
          if (data.rows.isEmpty) {
            return Center(child: Text(l10n.unavailableReviewEmpty));
          }
          final items = _items(l10n, data);
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) => switch (items[index]) {
              final _Header header => header.build(context),
              final LibraryRecoveryReviewTableData row => _ReviewCard(
                entry: row,
                onKeep: () => _setDisposition(row, 'keptForLater'),
                onRemoveFromLiked: _isRemovableLike(data, row)
                    ? () => _removeFromLiked([row])
                    : null,
              ),
              _ => const SizedBox.shrink(),
            },
          );
        },
      ),
    );
  }

  /// Intro and bulk actions, then Albums, Artists, and songs under their
  /// album (songs without an album name go last, under Other Songs).
  List<Object> _items(AppLocalizations l10n, UnavailableReviewData data) {
    int byTitle(
      LibraryRecoveryReviewTableData a,
      LibraryRecoveryReviewTableData b,
    ) => (a.savedTitle ?? '').toLowerCase().compareTo(
      (b.savedTitle ?? '').toLowerCase(),
    );
    List<LibraryRecoveryReviewTableData> ofType(String type) =>
        data.rows.where((row) => row.entityType == type).toList()
          ..sort(byTitle);
    final albums = ofType('album');
    final artists = ofType('artist');
    final groups = <String, _AlbumGroup>{};
    final other = <LibraryRecoveryReviewTableData>[];
    for (final row in ofType('song')) {
      final song = data.songs[row.oldId];
      final album = song?.albumName?.trim() ?? '';
      if (album.isEmpty) {
        other.add(row);
        continue;
      }
      final artist = song?.artistName?.trim() ?? '';
      groups
          .putIfAbsent('$album\u0000$artist', () => _AlbumGroup(album, artist))
          .rows
          .add(row);
    }
    final sortedGroups = groups.values.toList()
      ..sort((a, b) {
        final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        return byTitle != 0
            ? byTitle
            : a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
      });
    return <Object>[
      _Header.actions(
        intro: l10n.unavailableReviewIntro,
        onKeepAll: _keepAll,
        onRemoveAll: data.rows.any((r) => _isRemovableLike(data, r))
            ? () => _removeFromLiked([
                for (final r in data.rows)
                  if (_isRemovableLike(data, r)) r,
              ])
            : null,
      ),
      if (albums.isNotEmpty) ...[
        _Header.section(l10n.unavailableReviewSectionAlbums),
        ...albums,
      ],
      if (artists.isNotEmpty) ...[
        _Header.section(l10n.unavailableReviewSectionArtists),
        ...artists,
      ],
      for (final group in sortedGroups) ...[
        _Header.section(group.title, subtitle: group.artist),
        ...group.rows,
      ],
      if (other.isNotEmpty) ...[
        _Header.section(l10n.unavailableReviewSectionOtherSongs),
        ...other,
      ],
    ];
  }

  Future<void> _setDisposition(
    LibraryRecoveryReviewTableData entry,
    String disposition,
  ) async {
    await ref
        .read(navisDatabaseProvider)
        .librarySyncDao
        .setRecoveryReviewDisposition(id: entry.id, disposition: disposition);
  }

  Future<void> _keepAll() async {
    final serverId = ref.read(serverConfigStateProvider).asData?.value?.id;
    if (serverId == null) {
      return;
    }
    await ref
        .read(navisDatabaseProvider)
        .librarySyncDao
        .keepAllPendingRecoveryReview(serverId);
  }

  /// Asks first, then un-likes the rows in one transaction. A song the
  /// server no longer has, and every album or artist row (its old id is not
  /// in the catalog by construction), is cleared locally only (an unstar for
  /// such an id could never be delivered and would retry forever); a live
  /// song queues the unstar as before. Downloaded files are never deleted.
  Future<void> _removeFromLiked(
    List<LibraryRecoveryReviewTableData> entries,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.unavailableReviewRemoveConfirmTitle,
      message: l10n.unavailableReviewRemoveConfirmMessage(entries.length),
      confirmLabel: l10n.unavailableReviewRemoveConfirmAction,
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final database = ref.read(navisDatabaseProvider);
    await database.transaction(() async {
      // Re-read at apply time: a sync may have changed the songs meanwhile.
      final songs = {
        for (final song in await database.libraryDao.getSongsByIds([
          for (final entry in entries) entry.oldId,
        ]))
          song.id: song,
      };
      final goneIds = <String>[];
      final goneParents = <String, List<String>>{};
      for (final entry in entries) {
        final song = songs[entry.oldId];
        if (entry.entityType != 'song') {
          (goneParents[entry.entityType] ??= <String>[]).add(entry.oldId);
        } else if (_isRemoteRow(entry, song)) {
          continue;
        } else if (song != null && song.serverDeletedAt != null) {
          goneIds.add(entry.oldId);
        } else if (song != null) {
          await database.starSyncDao.setStarred(
            itemId: entry.oldId,
            itemType: 'song',
            liked: false,
          );
        }
        await database.librarySyncDao.setRecoveryReviewDisposition(
          id: entry.id,
          disposition: 'removedFromLiked',
        );
      }
      await database.starSyncDao.clearSongLikesLocally(goneIds);
      for (final MapEntry(key: type, value: ids) in goneParents.entries) {
        await database.starSyncDao.clearSongLikesLocally(ids, itemType: type);
      }
    });
  }
}

/// A non-row entry of the list: the intro with bulk actions, or a section or
/// album header.
class _Header {
  const _Header.actions({
    required String this.intro,
    required this.onKeepAll,
    required this.onRemoveAll,
  }) : title = null,
       subtitle = null;

  const _Header.section(String this.title, {this.subtitle})
    : intro = null,
      onKeepAll = null,
      onRemoveAll = null;

  final String? intro;
  final Future<void> Function()? onKeepAll;
  final Future<void> Function()? onRemoveAll;
  final String? title;
  final String? subtitle;

  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    if (intro != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(intro!, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                OutlinedButton(
                  onPressed: onKeepAll,
                  child: Text(l10n.unavailableReviewKeepAll),
                ),
                if (onRemoveAll != null)
                  TextButton(
                    onPressed: onRemoveAll,
                    child: Text(l10n.unavailableReviewRemoveAllFromLiked),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    final sub = subtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
      child: Semantics(
        header: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title!, style: theme.textTheme.titleSmall),
            if (sub != null && sub.isNotEmpty)
              Text(sub, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _ReviewCard extends ConsumerWidget {
  const new({
    required this.entry,
    required this.onKeep,
    required this.onRemoveFromLiked,
  });

  final LibraryRecoveryReviewTableData entry;
  final Future<void> Function() onKeep;

  /// Null when the row is not a song or is a remote catalog copy.
  final Future<void> Function()? onRemoveFromLiked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final subtitle = entry.savedSubtitle;
    final candidateIds = _parsedCandidateIds(entry);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              entry.savedTitle ?? l10n.unavailableReviewUnknownTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (subtitle != null && subtitle.isNotEmpty)
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              _reasonLabel(l10n),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                OutlinedButton(
                  onPressed: () => _findMatch(context, ref),
                  child: Text(l10n.unavailableReviewFindMatch),
                ),
                if (candidateIds.isNotEmpty)
                  OutlinedButton(
                    onPressed: () =>
                        _considerReplacements(context, ref, candidateIds),
                    child: Text(l10n.unavailableReviewPossibleReplacements),
                  ),
                TextButton(
                  onPressed: onKeep,
                  child: Text(l10n.unavailableReviewKeepForLater),
                ),
                if (onRemoveFromLiked != null)
                  TextButton(
                    onPressed: onRemoveFromLiked,
                    child: Text(l10n.unavailableReviewRemoveFromLiked),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _reasonLabel(AppLocalizations l10n) {
    return switch (entry.reason) {
      'ambiguousMatch' => l10n.unavailableReviewReasonAmbiguous,
      'conflictingMbid' => l10n.unavailableReviewReasonConflicting,
      _ => l10n.unavailableReviewReasonMissing,
    };
  }

  List<String> _parsedCandidateIds(LibraryRecoveryReviewTableData entry) {
    final json = entry.candidateJson;
    if (json == null || json.isEmpty) {
      return const <String>[];
    }
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) {
        return const <String>[];
      }
      final ids = decoded['candidateIds'];
      if (ids is! List) {
        return const <String>[];
      }
      return ids.whereType<String>().toList(growable: false);
    } on FormatException {
      return const <String>[];
    }
  }

  Future<void> _findMatch(BuildContext context, WidgetRef ref) async {
    final database = ref.read(navisDatabaseProvider);
    final title = entry.savedTitle?.trim();
    if (title == null || title.isEmpty) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    switch (entry.entityType) {
      case 'album':
        final candidates = await database.libraryDao.searchAlbumsLocal(
          title,
          limit: 25,
        );
        if (!context.mounted) return;
        final selected = await _pickFromCandidates<AlbumsTableData>(
          context,
          candidates,
          (album) => album.name,
          (album) => album.artistName ?? '',
        );
        if (selected != null && context.mounted) {
          await _previewAndApply(
            context,
            ref,
            newTitle: selected.name,
            newSubtitle: selected.artistName ?? '',
            newId: selected.id,
          );
        }
      case 'artist':
        final candidates = await database.libraryDao.searchArtistsLocal(
          title,
          limit: 25,
        );
        if (!context.mounted) return;
        final selected = await _pickFromCandidates<ArtistsTableData>(
          context,
          candidates,
          (artist) => artist.name,
          (artist) => '',
        );
        if (selected != null && context.mounted) {
          await _previewAndApply(
            context,
            ref,
            newTitle: selected.name,
            newSubtitle: '',
            newId: selected.id,
          );
        }
      default:
        final candidates = await database.libraryDao.searchSongsLocal(
          title,
          limit: 25,
        );
        if (candidates.isEmpty) {
          if (context.mounted) {
            showAppNotice(
              context,
              message: l10n.unavailableReviewNoMatchFound,
              level: AppNoticeLevel.info,
            );
          }
          return;
        }
        if (!context.mounted) return;
        final selected = await _pickFromCandidates<SongsTableData>(
          context,
          candidates,
          (song) => song.title,
          (song) => song.artistName ?? '',
        );
        if (selected != null && context.mounted) {
          await _previewAndApply(
            context,
            ref,
            newTitle: selected.title,
            newSubtitle: selected.artistName ?? '',
            newId: selected.id,
          );
        }
    }
  }

  Future<void> _considerReplacements(
    BuildContext context,
    WidgetRef ref,
    List<String> candidateIds,
  ) async {
    final database = ref.read(navisDatabaseProvider);
    switch (entry.entityType) {
      case 'album':
        final candidates = (await database.libraryDao.getAlbumsByIds(
          candidateIds,
        )).where((album) => album.id != entry.oldId).toList(growable: false);
        if (!context.mounted) return;
        final selected = await _pickFromCandidates<AlbumsTableData>(
          context,
          candidates,
          (album) => album.name,
          (album) => album.artistName ?? '',
        );
        if (selected != null && context.mounted) {
          await _previewAndApply(
            context,
            ref,
            newTitle: selected.name,
            newSubtitle: selected.artistName ?? '',
            newId: selected.id,
          );
        }
      case 'artist':
        final candidates = (await database.libraryDao.getArtistsByIds(
          candidateIds,
        )).where((artist) => artist.id != entry.oldId).toList(growable: false);
        if (!context.mounted) return;
        final selected = await _pickFromCandidates<ArtistsTableData>(
          context,
          candidates,
          (artist) => artist.name,
          (artist) => '',
        );
        if (selected != null && context.mounted) {
          await _previewAndApply(
            context,
            ref,
            newTitle: selected.name,
            newSubtitle: '',
            newId: selected.id,
          );
        }
      default:
        final candidates = (await database.libraryDao.getSongsByIds(
          candidateIds,
        )).where((song) => song.id != entry.oldId).toList(growable: false);
        if (!context.mounted) return;
        final selected = await _pickFromCandidates<SongsTableData>(
          context,
          candidates,
          (song) => song.title,
          (song) => song.artistName ?? '',
        );
        if (selected != null && context.mounted) {
          await _previewAndApply(
            context,
            ref,
            newTitle: selected.title,
            newSubtitle: selected.artistName ?? '',
            newId: selected.id,
          );
        }
    }
  }

  Future<T?> _pickFromCandidates<T>(
    BuildContext context,
    List<T> candidates,
    String Function(T) title,
    String Function(T) subtitle,
  ) async {
    if (candidates.isEmpty) {
      if (context.mounted) {
        showAppNotice(
          context,
          message: AppLocalizations.of(context)!.unavailableReviewNoMatchFound,
          level: AppNoticeLevel.info,
        );
      }
      return null;
    }
    if (!context.mounted) {
      return null;
    }
    return await showNavisModalSheet<T>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: candidates.length,
          itemBuilder: (sheetContext, index) {
            final candidate = candidates[index];
            return ListTile(
              title: Text(title(candidate)),
              subtitle: subtitle(candidate).isEmpty
                  ? null
                  : Text(subtitle(candidate)),
              onTap: () => Navigator.pop(sheetContext, candidate),
            );
          },
        ),
      ),
    );
  }

  /// Shows the old/new preview with the references the remap carries over
  /// and applies only after explicit confirmation.
  Future<void> _previewAndApply(
    BuildContext context,
    WidgetRef ref, {
    required String newTitle,
    required String newSubtitle,
    required String newId,
  }) async {
    if (!context.mounted || newId == entry.oldId) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final database = ref.read(navisDatabaseProvider);
    final references = await _collectReferences(database, entry);
    if (!context.mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _RelinkPreviewDialog(
        entry: entry,
        newTitle: newTitle,
        newSubtitle: newSubtitle,
        newId: newId,
        references: references,
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }

    // Revalidation at apply time (plan E8): the entry must still be pending
    // and the replacement must still exist in the current catalog.
    final stillPending = await (database.select(
      database.libraryRecoveryReviewTable,
    )..where((table) => table.id.equals(entry.id))).getSingleOrNull();
    if (stillPending == null || stillPending.disposition != 'pending') {
      if (context.mounted) {
        showAppNotice(
          context,
          message: l10n.unavailableReviewAlreadyResolved,
          level: AppNoticeLevel.info,
        );
      }
      return;
    }
    final replacementExists = switch (entry.entityType) {
      'album' => await database.libraryDao.getAlbumById(newId) != null,
      'artist' => await database.libraryDao.getArtistById(newId) != null,
      _ => await database.libraryDao.getSongById(newId) != null,
    };
    if (!replacementExists) {
      if (context.mounted) {
        showAppNotice(
          context,
          message: l10n.unavailableReviewStaleSelection,
          level: AppNoticeLevel.error,
        );
      }
      return;
    }

    try {
      switch (entry.entityType) {
        case 'album':
          await database.songIdentityDao.remapAlbumIdentity(
            oldAlbumId: entry.oldId,
            canonicalAlbumId: newId,
            matchReason: 'manualReview',
          );
        case 'artist':
          await database.songIdentityDao.remapArtistIdentity(
            oldArtistId: entry.oldId,
            canonicalArtistId: newId,
            matchReason: 'manualReview',
          );
        default:
          await database.songIdentityDao.remapSongIdentity(
            oldSongId: entry.oldId,
            canonicalSongId: newId,
            matchReason: 'manualReview',
          );
      }
      await database.librarySyncDao.setRecoveryReviewDisposition(
        id: entry.id,
        disposition: 'relinked',
      );
    } on Object catch (error) {
      AppLogger.warning('Manual relink failed for ${entry.oldId}: $error');
      if (context.mounted) {
        showAppNotice(
          context,
          message: l10n.unavailableReviewRelinkFailed,
          level: AppNoticeLevel.error,
        );
      }
    }
  }
}

class _RelinkPreviewDialog extends StatelessWidget {
  const new({
    required this.entry,
    required this.newTitle,
    required this.newSubtitle,
    required this.newId,
    required this.references,
  });

  final LibraryRecoveryReviewTableData entry;
  final String newTitle;
  final String newSubtitle;
  final String newId;
  final _ReferenceSummary references;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.unavailableReviewRelinkTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.unavailableReviewRelinkOld,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Text(entry.savedTitle ?? entry.oldId),
            if ((entry.savedSubtitle ?? '').isNotEmpty)
              Text(
                entry.savedSubtitle!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            Text(
              l10n.unavailableReviewRelinkNew,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Text(newTitle),
            if (newSubtitle.isNotEmpty)
              Text(newSubtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Text(
              l10n.unavailableReviewReferences,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 4),
            if (references.isEmpty)
              Text(
                l10n.unavailableReviewRefNone,
                style: Theme.of(context).textTheme.bodySmall,
              )
            else ...<Widget>[
              if (references.copies > 0)
                _referenceRow(
                  context,
                  l10n.unavailableReviewRefCopies(references.copies),
                ),
              if (references.playlistEntries > 0)
                _referenceRow(
                  context,
                  l10n.unavailableReviewRefPlaylists(
                    references.playlistEntries,
                  ),
                ),
              if (references.history > 0)
                _referenceRow(
                  context,
                  l10n.unavailableReviewRefHistory(references.history),
                ),
              if (references.queueEntries > 0)
                _referenceRow(
                  context,
                  l10n.unavailableReviewRefQueue(references.queueEntries),
                ),
              if (references.pendingAnnotations > 0)
                _referenceRow(
                  context,
                  l10n.unavailableReviewRefLikes(references.pendingAnnotations),
                ),
              if (references.followingSongs > 0)
                _referenceRow(
                  context,
                  l10n.unavailableReviewRefSongs(references.followingSongs),
                ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.unavailableReviewRelinkDismiss),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.unavailableReviewRelinkApply),
        ),
      ],
    );
  }

  Widget _referenceRow(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
