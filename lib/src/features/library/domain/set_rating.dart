import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/providers/app_providers.dart';

Future<void> setSongRating(
  String songId,
  int rating,
  WidgetRef ref,
) async {
  final db = ref.read(navisDatabaseProvider);
  final dao = db.libraryDao;
  final api = ref.read(subsonicApiProvider);
  final normalized = rating.clamp(0, 5);
  final current = await dao.getSongRating(songId);
  await dao.updateSongRating(songId, normalized == 0 ? null : normalized);

  if (api == null) {
    return;
  }

  try {
    await api.setRating(songId, normalized);
  } on SubsonicConnectionException {
    // Keep optimistic local state while offline.
  } on Object {
    await dao.updateSongRating(songId, current);
    rethrow;
  }
}

Future<void> setAlbumRating(
  String albumId,
  int rating,
  WidgetRef ref,
) async {
  final db = ref.read(navisDatabaseProvider);
  final dao = db.libraryDao;
  final api = ref.read(subsonicApiProvider);
  final normalized = rating.clamp(0, 5);
  final current = await dao.getAlbumRating(albumId);
  await dao.updateAlbumRating(albumId, normalized == 0 ? null : normalized);

  if (api == null) {
    return;
  }

  try {
    await api.setRating(albumId, normalized);
  } on SubsonicConnectionException {
    // Keep optimistic local state while offline.
  } on Object {
    await dao.updateAlbumRating(albumId, current);
    rethrow;
  }
}
