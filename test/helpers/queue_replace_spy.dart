import 'package:flutter/foundation.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';

/// Records the last queue replacement, whichever replace method a screen
/// uses, so Album Queue tests can assert the queued ids and start index.
@visibleForTesting
class QueueReplaceSpy extends QueueController {
  List<String>? lastReplaceIds;
  int? lastStartIndex;

  @override
  List<String> build() => const <String>[];

  void _record(List<String> ids, int startIndex) {
    lastReplaceIds = List<String>.unmodifiable(ids);
    lastStartIndex = startIndex;
    state = lastReplaceIds!;
  }

  @override
  Future<void> replace(
    List<String> ids, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async => _record(ids, startIndex);

  @override
  Future<void> replaceWithTableData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async => _record(songs.map((s) => s.id).toList(), startIndex);

  @override
  Future<void> replaceWithSongs(
    List<Song> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    bool notifyMixSessionReset = true,
  }) async => _record(songs.map((s) => s.id).toList(), startIndex);
}
