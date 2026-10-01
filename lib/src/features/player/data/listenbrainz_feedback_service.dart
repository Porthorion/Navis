import 'dart:async';

import 'package:dio/dio.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/database/daos/listenbrainz_feedback_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/utils/app_logger.dart';

class ListenBrainzFeedbackCredentials {
  const new({required this.userToken});

  final String userToken;
}

class ListenBrainzFeedbackService {
  new({
    required this._dao,
    required this._libraryDao,
    required this._readCredentials,
    required this._createClient,
    required this._readReachable,
    this._onInvalidToken,
  });

  final ListenBrainzFeedbackDao _dao;
  final LibraryDao _libraryDao;
  final Future<ListenBrainzFeedbackCredentials?> Function() _readCredentials;
  final ListenBrainzApiClient Function() _createClient;
  final bool Function() _readReachable;
  final void Function()? _onInvalidToken;

  bool _flushing = false;

  Future<void> enqueueSongFeedback(String songId, {required bool liked}) async {
    final credentials = await _readCredentials();
    if (credentials == null) {
      return;
    }
    final song = await _libraryDao.getSongById(songId);
    final title = song?.title.trim() ?? '';
    final artist = song?.artistName?.trim() ?? '';
    if (song == null || title.isEmpty || artist.isEmpty) {
      AppLogger.debug(
        'ListenBrainz feedback skipped for $songId: missing local metadata.',
      );
      return;
    }
    await _dao.queueFeedback(
      songId: song.id,
      score: liked ? 1 : 0,
      recordingMbid: song.recordingMbid,
      title: title,
      artist: artist,
      album: song.albumName,
    );
    unawaited(flush());
  }

  Future<void> flush() async {
    if (_flushing || !_readReachable()) {
      return;
    }
    _flushing = true;
    try {
      final credentials = await _readCredentials();
      if (credentials == null) {
        return;
      }
      final client = _createClient();
      final pending = await _dao.getDueFeedback(now: DateTime.now());
      for (final entry in pending) {
        if (!_readReachable()) {
          return;
        }
        try {
          final recordingMbid = await _resolveRecordingMbid(
            client,
            credentials.userToken,
            entry,
          );
          if (recordingMbid == null) {
            AppLogger.debug(
              'ListenBrainz feedback dropped for ${entry.songId}: '
              'metadata lookup returned no recording MBID.',
            );
            await _dao.removeFeedback(entry.id);
            continue;
          }
          await client.submitRecordingFeedback(
            userToken: credentials.userToken,
            recordingMbid: recordingMbid,
            score: entry.score,
          );
          await _dao.removeFeedback(entry.id);
        } on ListenBrainzInvalidTokenException {
          _onInvalidToken?.call();
          await _dao.removeFeedback(entry.id);
          return;
        } on DioException catch (error) {
          final status = error.response?.statusCode;
          if (status == 401 || status == 403) {
            _onInvalidToken?.call();
            await _dao.removeFeedback(entry.id);
            return;
          }
          await _dao.markAttemptFailed(entry, error.toString());
          if (_isConnectivityError(error)) {
            return;
          }
        } on Object catch (error) {
          await _dao.markAttemptFailed(entry, error.toString());
        }
      }
    } finally {
      _flushing = false;
    }
  }

  Future<String?> _resolveRecordingMbid(
    ListenBrainzApiClient client,
    String userToken,
    ListenBrainzFeedbackQueueTableData entry,
  ) async {
    final cached = entry.recordingMbid?.trim();
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    final lookup = await client.lookupRecordingMbid(
      userToken: userToken,
      title: entry.title,
      artist: entry.artist,
      album: entry.album,
    );
    final mbid = lookup?.trim();
    if (mbid == null || mbid.isEmpty) {
      return null;
    }
    await _libraryDao.updateSongRecordingMbid(entry.songId, mbid);
    await _dao.updateRecordingMbid(entry.id, mbid);
    return mbid;
  }

  bool _isConnectivityError(DioException error) {
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.unknown;
  }
}

Future<ListenBrainzFeedbackCredentials?> readListenBrainzFeedbackCredentials({
  required AppSettingsModel settings,
  required Future<String?> Function() readToken,
}) async {
  if (!settings.listenBrainzScrobblingEnabled ||
      !settings.listenBrainzTokenValid) {
    return null;
  }
  final token = (await readToken())?.trim() ?? '';
  if (token.isEmpty) {
    return null;
  }
  return ListenBrainzFeedbackCredentials(userToken: token);
}
