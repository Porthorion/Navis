part of 'navis_audio_handler.dart';

extension _NavisDiagnostics on NavisAudioHandler {
  void _invalidatePendingStartupSelection() {
    _activeStartupTrace?.mark('superseded');
    _activeStartupTrace = null;
  }

  void _acceptStartupSelection(String songId, {required bool isExternal}) {
    final trace = _activeStartupTrace;
    if (trace == null || !trace.awaitingHandler || trace.songId != songId) {
      beginPlaybackSelection(songId, isExternal: isExternal);
    }
    _activeStartupTrace?.awaitingHandler = false;
    _activeStartupTrace?.mark('handlerAccepted');
  }

  /// Whether [player] holds exactly the materialised queue, by song id (an
  /// id remapped to its canonical song since it was loaded still matches).
  bool _sequenceMatchesQueue(AudioPlayer player) {
    final sequence = player.sequence;
    if (sequence.length != _queueItems.length) return false;
    for (var i = 0; i < sequence.length; i++) {
      final nativeId = navisNativeSourceSongId(sequence[i]);
      if (nativeId == null) return false;
      final id = _queueItems[i].id;
      if (nativeId != id &&
          _canonicalSongId(nativeId) != _canonicalSongId(id)) {
        return false;
      }
    }
    return true;
  }

  void _traceSourceResolved(
    SongsTableData song,
    ResolvedPlaybackSource source,
  ) {
    _transportTrace.record('sourceResolved', () {
      final query =
          (source.uri ?? source.lockCachingStreamUri)?.queryParameters ??
          const <String, String>{};
      final cachedPath = source.cachedFilePath;
      return <String, Object?>{
        'songId': song.id,
        'sourceKind': source.kind.name,
        // Never the URL: it carries credentials.
        'format': query['format'],
        'maxBitRate': query['maxBitRate'],
        'timeOffset': query['timeOffset'],
        'sidecar': source.sidecarCacheFilePath != null,
        if (source.isLocal)
          'localFolder': source.uri!.pathSegments.reversed.skip(1).firstOrNull,
        if (cachedPath != null) 'cacheFile': true,
      };
    });
  }

  int? _partialCacheBytesForSong(String? songId) {
    if (songId == null) {
      return null;
    }
    if (_sidecarDownloader.activeSongId == songId) {
      return _sidecarDownloader.activeReceivedBytes;
    }
    for (final entry in _rollingCacheActivities.entries) {
      if (entry.value.songId != songId) {
        continue;
      }
      final partFile = File('${entry.key}.part');
      if (partFile.existsSync()) {
        return partFile.lengthSync();
      }
      final completed = File(entry.key);
      if (completed.existsSync()) {
        return completed.lengthSync();
      }
    }
    String? cachedPath;
    for (final item in _queueItems) {
      if (item.id != songId) {
        continue;
      }
      cachedPath = item.extras?['cachedFilePath'] as String?;
      break;
    }
    if (cachedPath == null || cachedPath.isEmpty) {
      return null;
    }
    final partFile = File('$cachedPath.part');
    if (partFile.existsSync()) {
      return partFile.lengthSync();
    }
    final completed = File(cachedPath);
    if (completed.existsSync()) {
      return completed.lengthSync();
    }
    return null;
  }
}
