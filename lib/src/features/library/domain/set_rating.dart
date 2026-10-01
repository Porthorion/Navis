import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';

Future<void> setSongRating(String songId, int rating, WidgetRef ref) => ref
    .read(navisDatabaseProvider)
    .starSyncDao
    .setRating(itemId: songId, itemType: 'song', rating: rating);

Future<void> setAlbumRating(String albumId, int rating, WidgetRef ref) => ref
    .read(navisDatabaseProvider)
    .starSyncDao
    .setRating(itemId: albumId, itemType: 'album', rating: rating);
