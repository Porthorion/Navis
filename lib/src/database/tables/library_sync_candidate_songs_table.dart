import 'package:drift/drift.dart';

class LibrarySyncCandidateSongsTable extends Table {
  @override
  String get tableName => 'library_sync_candidate_songs';

  IntColumn get serverId => integer()();

  IntColumn get generation => integer()();

  TextColumn get id => text()();

  TextColumn get title => text()();

  TextColumn get albumId => text().nullable()();

  TextColumn get artistId => text().nullable()();

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

  TextColumn get recordingMbid => text().nullable()();

  IntColumn get userRating => integer().nullable()();

  IntColumn get playCount => integer().nullable()();

  DateTimeColumn get createdAt => dateTime().nullable()();

  RealColumn get replayGainTrackGain => real().nullable()();

  RealColumn get replayGainAlbumGain => real().nullable()();

  RealColumn get replayGainTrackPeak => real().nullable()();

  RealColumn get replayGainAlbumPeak => real().nullable()();

  /// Null while the candidate still needs comparison, zero when it matches
  /// the committed row, and one when promotion must insert or update it.
  IntColumn get applyState => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {serverId, generation, id};
}
