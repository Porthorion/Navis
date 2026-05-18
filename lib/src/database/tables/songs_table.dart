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

  DateTimeColumn get starred => dateTime().nullable()();

  IntColumn get userRating => integer().nullable()();

  IntColumn get playCount => integer().nullable()();

  DateTimeColumn get createdAt => dateTime().nullable()();

  /// Local-only retention marker for songs deleted from the server but kept
  /// because a complete permanent download still exists on disk.
  DateTimeColumn get serverDeletedAt => dateTime().nullable()();

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
