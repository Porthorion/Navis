import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/artist_ref_converter.dart';
import 'package:navis/src/database/tables/artists_table.dart';

class AlbumsTable extends Table {
  @override
  String get tableName => 'albums';

  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get artistId => text().nullable().references(
    ArtistsTable,
    #id,
    onDelete: KeyAction.setNull,
  )();

  TextColumn get artistName => text().nullable()();

  /// OpenSubsonic multi-artist list, JSON-encoded.
  ///
  /// Populated from the `artists` field in OpenSubsonic `AlbumID3` responses.
  /// Empty list (`'[]'`) on standard Subsonic servers; fall back to the legacy
  /// [artistId]/[artistName] pair in that case.
  TextColumn get artists => text()
      .withDefault(const Constant('[]'))
      .map(const ArtistRefListConverter())();

  IntColumn get songCount => integer().nullable()();

  IntColumn get duration => integer().nullable()();

  IntColumn get year => integer().nullable()();

  TextColumn get coverArt => text().nullable()();

  /// Incremented on targeted artwork recovery so cached cover bytes keyed to
  /// the previous revision stop satisfying new requests. Zero keeps the
  /// legacy cache-key layout so existing offline artwork stays valid.
  /// Nullable so rows never refreshed keep legacy data-class behavior;
  /// treat null as revision zero when composing cache keys.
  IntColumn get coverArtRevision => integer().nullable()();

  /// MusicBrainz release identifier, when the server supplies one. Used to
  /// map albums across server ID changes without metadata guessing.
  TextColumn get releaseMbid => text().nullable()();

  /// Typed catalog availability. Null reads as present for legacy rows.
  TextColumn get catalogAvailability => text().nullable()();

  BoolColumn get songsHydrated =>
      boolean().withDefault(const Constant(false))();

  /// Last complete track snapshot, independent of album-header/index changes.
  DateTimeColumn get songsVerifiedAt => dateTime().nullable()();

  DateTimeColumn get starred => dateTime().nullable()();

  IntColumn get userRating => integer().nullable()();

  IntColumn get playCount => integer().nullable()();

  /// When this album was first persisted to the local database (synced from
  /// server). Internal synchronization metadata; never an ordering authority.
  DateTimeColumn get syncedAt => dateTime().nullable()();

  /// When the album was added to the Subsonic server library.
  /// Populated from the `created` field in `getAlbumList2` responses.
  /// More accurate than [syncedAt] for "Recently Added" ordering.
  DateTimeColumn get serverCreatedAt => dateTime().nullable()();

  /// Position in the last server `newest` response, where lower values are
  /// newer.  Compatible servers can omit [serverCreatedAt] or assign the same
  /// timestamp to several albums, so this preserves the server's order as a
  /// stable Recently Added tie-breaker.
  IntColumn get recentlyAddedRank => integer().nullable()();

  /// True for lightweight parent rows created from online search/playback
  /// results before the authoritative library sync has observed the album.
  BoolColumn get isProvisional =>
      boolean().withDefault(const Constant(false))();

  /// True when the item belongs to an external catalog and has not been
  /// imported into the server library.
  BoolColumn get isExternal => boolean().withDefault(const Constant(false))();

  /// Authoritative catalog snapshot generation that last observed this row.
  IntColumn get catalogGeneration => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
