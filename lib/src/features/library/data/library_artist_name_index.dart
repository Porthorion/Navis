import 'dart:isolate';

import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// Library artists by `normalizeMetadata` name, for matching names from
/// outside the server (Deezer's related artists) in time proportional to the
/// names asked for, not to the library.
class LibraryArtistNameIndex {
  const new _(this._byName);

  /// Above this many artists the names are normalized in a background
  /// isolate, which costs a copy but keeps the UI isolate free.
  static const isolateThreshold = 64;

  final Map<String, ArtistsTableData> _byName;

  /// Indexes [artists]. When several share a name, the one from the server
  /// library wins over a remote-catalogue one, then the one with more albums,
  /// then the smaller id.
  static Future<LibraryArtistNameIndex> build(
    List<ArtistsTableData> artists,
  ) async {
    final names = <String>[for (final artist in artists) artist.name];
    final keys = names.length > isolateThreshold
        ? await Isolate.run(
            () => names.map(normalizeMetadata).toList(growable: false),
          )
        : names.map(normalizeMetadata).toList(growable: false);
    final byName = <String, ArtistsTableData>{};
    for (var i = 0; i < artists.length; i++) {
      final key = keys[i];
      if (key.isEmpty) continue;
      final current = byName[key];
      if (current == null || _isPreferred(artists[i], over: current)) {
        byName[key] = artists[i];
      }
    }
    return LibraryArtistNameIndex._(byName);
  }

  /// The library artists named like [names], keyed by normalized name.
  Map<String, ArtistsTableData> lookupAll(Iterable<String> names) {
    final found = <String, ArtistsTableData>{};
    for (final name in names) {
      final key = normalizeMetadata(name);
      final artist = _byName[key];
      if (artist != null) found[key] = artist;
    }
    return found;
  }

  static bool _isPreferred(
    ArtistsTableData candidate, {
    required ArtistsTableData over,
  }) {
    if (candidate.isExternal != over.isExternal) return !candidate.isExternal;
    final byAlbums = (candidate.albumCount ?? 0).compareTo(
      over.albumCount ?? 0,
    );
    if (byAlbums != 0) return byAlbums > 0;
    return candidate.id.compareTo(over.id) < 0;
  }
}

/// Keeps one [LibraryArtistNameIndex] until the artists table changes.
///
/// [markStale] only bumps a revision; the next [current] call rebuilds, so a
/// library sync writing many artist batches costs one rebuild, on the next
/// lookup, instead of one per batch.
class LibraryArtistNameIndexCache {
  new({required this._loadArtists});

  final Future<List<ArtistsTableData>> Function() _loadArtists;
  int _revision = 0;
  ({int revision, Future<LibraryArtistNameIndex> index})? _current;

  /// The artists table changed; the next [current] call rebuilds.
  void markStale() => _revision++;

  /// The index for the library as it is now. Callers at the same time share
  /// one build; a failed build is not kept.
  Future<LibraryArtistNameIndex> current() {
    final cached = _current;
    if (cached != null && cached.revision == _revision) return cached.index;
    final index = _loadArtists().then(LibraryArtistNameIndex.build);
    _current = (revision: _revision, index: index);
    index.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_current?.index, index)) _current = null;
      },
    );
    return index;
  }
}
