import 'package:navis/src/database/navis_database.dart';

class AlbumYearSection {
  const new({
    required this.title,
    required this.decadeStart,
    required this.albums,
    this.year,
    this.isUnknownYear = false,
  });

  final String title;
  final int? decadeStart;
  final int? year;
  final bool isUnknownYear;
  final List<AlbumsTableData> albums;
}

class AlbumTileDownloadState {
  const new({
    required this.fullyDownloaded,
    required this.downloadedTrackCount,
    required this.totalTrackCount,
    required this.queued,
    required this.progress,
  });

  const new idle()
    : fullyDownloaded = false,
      downloadedTrackCount = 0,
      totalTrackCount = 0,
      queued = false,
      progress = 0;

  final bool fullyDownloaded;
  final int downloadedTrackCount;
  final int totalTrackCount;
  final bool queued;
  final double progress;

  @override
  bool operator ==(Object other) =>
      other is AlbumTileDownloadState &&
      other.fullyDownloaded == fullyDownloaded &&
      other.downloadedTrackCount == downloadedTrackCount &&
      other.totalTrackCount == totalTrackCount &&
      other.queued == queued &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(
    fullyDownloaded,
    downloadedTrackCount,
    totalTrackCount,
    queued,
    progress,
  );
}
