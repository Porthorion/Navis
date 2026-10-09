part of 'navis_audio_handler.dart';

extension _NavisRadio on NavisAudioHandler {
  RadioMetadataService _newRadioMetadataService() => RadioMetadataService(
    handler: this,
    player: _player,
    dio: _createRadioMetadataDio?.call(),
    isAllowed: _readRadioMetadataAllowed,
  );

  /// Starts an Instant Mix seeded from the current song or local library.
  Future<bool> _playInstantMixFromCurrentSong() async {
    final current = _currentMediaItem;
    // Android Auto may start before a media item or the Flutter shell exists.
    final seedId = current?.id ?? await _coldStartMixSeed();
    if (seedId == null) return false;

    if (current != null) {
      try {
        await _preferredMixToggleCallback(seedId);
        return true;
      } on Object catch (e, st) {
        AppLogger.warning('Instant Mix (toggle) failed for $seedId: $e\n$st');
      }
    }

    try {
      await _preferredMixCallback(seedId);
      return true;
    } on Object catch (e, st) {
      AppLogger.warning(
        'Instant Mix (preferred mode) failed for $seedId: $e\n$st',
      );
      return false;
    }
  }

  Future<String?> _coldStartMixSeed() async {
    final liked = await _libraryDao.watchAllStarredSongs().first;
    if (liked.isNotEmpty) return liked.first.id;
    final first = await _libraryDao.getSongsSorted(
      SongSortOrder.newest,
      limit: 1,
    );
    return first.isEmpty ? null : first.first.id;
  }

  Future<bool> _startInstantRadio({required bool autoPlay}) =>
      _startPersonalRadio(autoPlay);

  Future<void> _restorePreviousQueueAfterRadio(
    OperationToken token, {
    required String context,
  }) async {
    if (_queueItems.isNotEmpty || _radioStation != null) return;
    try {
      await _restoreSavedQueue(token: token);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Queue restore after $context failed: $error\n$stackTrace',
      );
    }
  }
}
