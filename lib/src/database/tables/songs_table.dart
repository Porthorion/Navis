import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';

class SongsTable extends Table {
  @override
  String get tableName => 'songs';

  TextColumn get id => text()();

  TextColumn get title => text()();

  TextColumn get albumId => text().nullable().references(
    AlbumsTable,
    #id,
    onDelete: KeyAction.setNull,
  )();

  TextColumn get artistId => text().nullable().references(
    ArtistsTable,
    #id,
    onDelete: KeyAction.setNull,
  )();

  TextColumn get artistName => text().nullable()();

  TextColumn get albumName => text().nullable()();

  IntColumn get track => integer().nullable()();

  IntColumn get discNumber => integer().nullable()();

  IntColumn get duration => integer().nullable()();

  IntColumn get bitRate => integer().nullable()();

  IntColumn get sampleRate => integer().nullable()();

  TextColumn get contentType => text().nullable()();

  TextColumn get suffix => text().nullable()();

  IntColumn get size => integer().nullable()();

  TextColumn get coverArt => text().nullable()();

  /// Incremented on targeted artwork recovery so cached cover bytes keyed to
  /// the previous revision stop satisfying new requests. Zero keeps the
  /// legacy cache-key layout so existing offline artwork stays valid.
  /// Nullable so rows never refreshed keep legacy data-class behavior;
  /// treat null as revision zero when composing cache keys.
  IntColumn get coverArtRevision => integer().nullable()();

  DateTimeColumn get starred => dateTime().nullable()();

  TextColumn get recordingMbid => text().nullable()();

  /// MusicBrainz release identifier for the containing album, when the server
  /// supplies one. Stable across server ID changes and never matched fuzzily.
  TextColumn get albumMbid => text().nullable()();

  /// MusicBrainz artist identifier, when the server supplies one.
  TextColumn get artistMbid => text().nullable()();

  IntColumn get userRating => integer().nullable()();

  IntColumn get playCount => integer().nullable()();

  DateTimeColumn get createdAt => dateTime().nullable()();

  /// Local-only retention marker for songs deleted from the server but kept
  /// because a complete permanent download still exists on disk.
  DateTimeColumn get serverDeletedAt => dateTime().nullable()();

  /// Typed availability beyond the legacy [serverDeletedAt] marker. Null
  /// reads as present for rows written before typed availability existed.
  /// Confirmed-missing rows with favorites or references are retained for
  /// recovery review instead of being deleted.
  TextColumn get catalogAvailability => text().nullable()();

  /// True when the row was persisted only to make an online search result
  /// playable and has not yet been confirmed by authoritative library sync.
  BoolColumn get isProvisional =>
      boolean().withDefault(const Constant(false))();

  /// True when the item belongs to an external catalog and has not been
  /// imported into the server library.
  BoolColumn get isExternal => boolean().withDefault(const Constant(false))();

  /// Authoritative catalog snapshot generation that last observed this row.
  IntColumn get catalogGeneration => integer().nullable()();

  /// ReplayGain track gain in dB (from OpenSubsonic replayGain object).
  RealColumn get replayGainTrackGain => real().nullable()();

  /// ReplayGain album gain in dB.
  RealColumn get replayGainAlbumGain => real().nullable()();

  /// ReplayGain track peak (linear, 0.0–1.0+).
  RealColumn get replayGainTrackPeak => real().nullable()();

  /// ReplayGain album peak (linear, 0.0–1.0+).
  RealColumn get replayGainAlbumPeak => real().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
