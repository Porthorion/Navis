# Artist Detail — Play & Shuffle Buttons

**Date:** 2026-04-02
**Status:** Approved

## Goal

Add a Play + Shuffle button pair to the artist detail screen so users can queue all songs by an artist in order or shuffled, mirroring the pattern already used on the album detail screen.

## Data Layer

### LibraryDao — new method

Add `watchSongsByArtist(String artistId)` to `LibraryDao`:

- Query: `SELECT * FROM songs WHERE artist_id = ?` ordered by album year ASC, album name ASC, track number ASC.
- Returns `Stream<List<SongsTableData>>` for reactivity (sync updates are reflected immediately).
- Follows the same shape as the existing `watchSongsByAlbum(String albumId)`.

### Provider — new StreamProvider.family

Add `songsByArtistProvider` in `lib/src/providers/app_providers.dart`:

```dart
final songsByArtistProvider =
    StreamProvider.family<List<SongsTableData>, String>((ref, artistId) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchSongsByArtist(artistId);
});
```

Mirrors `albumsByArtistProvider` which already lives in `app_providers.dart`.

## UI Layer

### State additions in `_ArtistDetailScreenState`

- `bool _isQueueActionInFlight = false` — guards against double-taps, same pattern as album detail.

### New method `_queueArtist`

```dart
Future<void> _queueArtist(List<SongsTableData> songs, {required bool shuffle}) async {
  if (songs.isEmpty || _isQueueActionInFlight) return;
  setState(() => _isQueueActionInFlight = true);
  try {
    final queue = songs.map((s) => s.id).toList();
    if (shuffle) queue.shuffle(Random());
    await ref.read(queueProvider.notifier).replace(queue, autoPlay: true);
  } on Object {
    if (!mounted) return;
    AppNoticeMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.playbackActionFailed)),
    );
  } finally {
    if (mounted) setState(() => _isQueueActionInFlight = false);
  }
}
```

### Widget changes

In the `build` method, watch the new provider:

```dart
final songs = ref.watch(songsByArtistProvider(widget.artistId));
```

Insert a `Padding` widget just before the existing "Albums" section heading (`l10n.artistDetailAlbumsSection`).
Use `songs.asData?.value` to conditionally include it in the `ListView` children list:

```dart
final songList = songs.asData?.value ?? const [];
if (songList.isNotEmpty)
  Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          onPressed: _isQueueActionInFlight ? null : () => unawaited(_queueArtist(songList, shuffle: false)),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(l10n.albumDetailPlayAction),
        ),
        FilledButton.tonalIcon(
          onPressed: _isQueueActionInFlight ? null : () => unawaited(_queueArtist(songList, shuffle: true)),
          icon: const Icon(Icons.shuffle, size: 18),
          label: Text(l10n.albumDetailShuffleAction),
        ),
      ],
    ),
  ),
```

- Buttons are hidden (not just disabled) when the artist has no songs in the local DB.
- Buttons are disabled while `_isQueueActionInFlight` is true.
- No new l10n strings needed — reuses `albumDetailPlayAction` and `albumDetailShuffleAction`.
- No loading indicator for this row — the album grid below already covers the loading UX.

## Files to Change

| File | Change |
|------|--------|
| `lib/src/database/daos/library_dao.dart` | Add `watchSongsByArtist` |
| `lib/src/providers/app_providers.dart` | Add `songsByArtistProvider` |
| `lib/src/features/library/presentation/artist_detail_screen.dart` | Watch provider, add state + method + button row |

## What This Does Not Change

- No new l10n strings.
- No schema changes.
- No changes to the artists list page.
- No changes to the album detail screen.
