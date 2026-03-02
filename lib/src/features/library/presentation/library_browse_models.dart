import 'package:navis/src/database/navis_database.dart';

enum AlbumViewMode { standard, byYear }

class AlbumYearSection {
  const AlbumYearSection({
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
  const AlbumTileDownloadState({
    required this.fullyDownloaded,
    required this.downloadedTrackCount,
    required this.totalTrackCount,
    required this.queued,
    required this.progress,
  });

  const AlbumTileDownloadState.idle()
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
}
