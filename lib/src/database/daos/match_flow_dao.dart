import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/match_flow_songs_table.dart';
import 'package:navis/src/database/tables/match_flows_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';
import 'package:uuid/uuid.dart';

part 'match_flow_dao.g.dart';

enum MatchFlowFailure { songAlreadyInFlow, flowMissing, masterInAnotherFlow }

class MatchFlowException implements Exception {
  const new(this.failure);

  final MatchFlowFailure failure;
}

class MatchFlowSongEntry {
  const new({required this.link, required this.song});

  final MatchFlowSongsTableData link;
  final SongsTableData? song;
}

class MatchFlowWithSongs {
  const new({required this.flow, required this.songs});

  final MatchFlowsTableData flow;
  final List<MatchFlowSongEntry> songs;
}

class MatchFlowExpansionResult {
  const new({required this.songIds, required this.startIndex});

  final List<String> songIds;
  final int startIndex;
}

@DriftAccessor(tables: [MatchFlowsTable, MatchFlowSongsTable, SongsTable])
class MatchFlowDao extends DatabaseAccessor<NavisDatabase>
    with NavisDaoTransactions, _$MatchFlowDaoMixin {
  new(super.attachedDatabase);

  static const String defaultFlowName = 'New Flow';

  Stream<List<MatchFlowWithSongs>> watchFlowsWithSongs() {
    final query =
        select(matchFlowsTable).join([
          leftOuterJoin(
            matchFlowSongsTable,
            matchFlowSongsTable.flowId.equalsExp(matchFlowsTable.id),
          ),
          leftOuterJoin(
            songsTable,
            songsTable.id.equalsExp(matchFlowSongsTable.songId),
          ),
        ])..orderBy([
          OrderingTerm.desc(matchFlowsTable.createdAt),
          OrderingTerm.asc(matchFlowsTable.id),
          OrderingTerm.asc(matchFlowSongsTable.sortOrder),
          OrderingTerm.asc(matchFlowSongsTable.songId),
        ]);
    return query.watch().map(_mapFlowRows);
  }

  Future<List<MatchFlowWithSongs>> getFlowsWithSongs() async {
    final flows =
        await (select(matchFlowsTable)..orderBy([
              (t) => OrderingTerm.desc(t.createdAt),
              (t) => OrderingTerm.asc(t.id),
            ]))
            .get();
    if (flows.isEmpty) return const <MatchFlowWithSongs>[];
    final links =
        await (select(matchFlowSongsTable)..orderBy([
              (t) => OrderingTerm.asc(t.sortOrder),
              (t) => OrderingTerm.asc(t.songId),
            ]))
            .get();
    final songIds = links.map((link) => link.songId).toSet().toList();
    final songs = songIds.isEmpty
        ? const <SongsTableData>[]
        : await (select(songsTable)..where((t) => t.id.isIn(songIds))).get();
    final songsById = <String, SongsTableData>{
      for (final song in songs) song.id: song,
    };
    final linksByFlow = <String, List<MatchFlowSongEntry>>{};
    for (final link in links) {
      (linksByFlow[link.flowId] ??= <MatchFlowSongEntry>[]).add(
        MatchFlowSongEntry(link: link, song: songsById[link.songId]),
      );
    }
    return flows
        .map(
          (flow) => MatchFlowWithSongs(
            flow: flow,
            songs: List<MatchFlowSongEntry>.unmodifiable(
              linksByFlow[flow.id] ?? const <MatchFlowSongEntry>[],
            ),
          ),
        )
        .toList(growable: false);
  }

  Future<String> createFlow({String? name}) async {
    final now = DateTime.now();
    final id = const Uuid().v4();
    await into(matchFlowsTable).insert(
      MatchFlowsTableCompanion.insert(
        id: id,
        name: _normalizedName(name),
        enabled: const Value(true),
        createdAt: now,
        updatedAt: now,
      ),
    );
    return id;
  }

  Future<void> renameFlow(String flowId, String name) async {
    await _updateFlow(
      flowId,
      MatchFlowsTableCompanion(
        name: Value(_normalizedName(name)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteFlow(String flowId) {
    return (delete(matchFlowsTable)..where((t) => t.id.equals(flowId))).go();
  }

  Future<void> setFlowEnabled(String flowId, {required bool enabled}) async {
    await _updateFlow(
      flowId,
      MatchFlowsTableCompanion(
        enabled: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> addSong(String flowId, String songId) async {
    final id = songId.trim();
    if (id.isEmpty) return;
    await transaction(() async {
      await _ensureFlowExists(flowId);
      final existing = await _orderedLinks(flowId);
      if (existing.any((link) => link.songId == id)) {
        throw const MatchFlowException(MatchFlowFailure.songAlreadyInFlow);
      }
      if (existing.isEmpty) {
        await _ensureMasterAvailable(id, excludingFlowId: flowId);
      }
      final now = DateTime.now();
      await into(matchFlowSongsTable).insert(
        MatchFlowSongsTableCompanion.insert(
          flowId: flowId,
          songId: id,
          sortOrder: existing.length,
          addedAt: now,
        ),
      );
      await _touchFlow(flowId, now);
    });
  }

  Future<void> removeSong(String flowId, String songId) async {
    final id = songId.trim();
    if (id.isEmpty) return;
    await transaction(() async {
      final links = await _orderedLinks(flowId);
      final index = links.indexWhere((link) => link.songId == id);
      if (index < 0) return;
      final next = links.where((link) => link.songId != id).toList();
      if (index == 0 && next.isNotEmpty) {
        await _ensureMasterAvailable(
          next.first.songId,
          excludingFlowId: flowId,
        );
      }
      await (delete(
        matchFlowSongsTable,
      )..where((t) => t.flowId.equals(flowId) & t.songId.equals(id))).go();
      await _writeOrder(flowId, next);
      await _touchFlow(flowId, DateTime.now());
    });
  }

  Future<void> reorderSong(
    String flowId,
    String songId, {
    required int newIndex,
  }) async {
    final id = songId.trim();
    if (id.isEmpty) return;
    await transaction(() async {
      final links = await _orderedLinks(flowId);
      final oldMaster = links.isEmpty ? null : links.first.songId;
      final oldIndex = links.indexWhere((link) => link.songId == id);
      if (oldIndex < 0) return;
      final moved = links.removeAt(oldIndex);
      final target = newIndex.clamp(0, links.length);
      links.insert(target, moved);
      if (links.isNotEmpty && links.first.songId != oldMaster) {
        await _ensureMasterAvailable(
          links.first.songId,
          excludingFlowId: flowId,
        );
      }
      await _writeOrder(flowId, links);
      await _touchFlow(flowId, DateTime.now());
    });
  }

  Future<MatchFlowExpansionResult> expandQueueSongIds(
    List<String> songIds, {
    required int startIndex,
    required bool enabled,
  }) async {
    final normalized = songIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (!enabled || normalized.isEmpty) {
      return MatchFlowExpansionResult(
        songIds: normalized,
        startIndex: normalized.isEmpty
            ? 0
            : startIndex.clamp(0, normalized.length - 1),
      );
    }

    final masters = normalized.toSet().toList(growable: false);
    final rows = await customSelect(
      '''
      SELECT m.flow_id, m.song_id, m.sort_order
      FROM match_flow_songs master
      JOIN match_flows f ON f.id = master.flow_id
      JOIN match_flow_songs m ON m.flow_id = master.flow_id
      WHERE f.enabled = 1
        AND master.sort_order = 0
        AND master.song_id IN (${masters.map((_) => '?').join(',')})
      ORDER BY m.flow_id ASC, m.sort_order ASC;
      ''',
      variables: masters.map(Variable<String>.new).toList(),
      readsFrom: {matchFlowsTable, matchFlowSongsTable},
    ).get();
    if (rows.isEmpty) {
      return MatchFlowExpansionResult(
        songIds: normalized,
        startIndex: startIndex.clamp(0, normalized.length - 1),
      );
    }

    final flowSongsByFlow = <String, List<String>>{};
    final masterByFlow = <String, String>{};
    for (final row in rows) {
      final flowId = row.read<String>('flow_id');
      final songId = row.read<String>('song_id');
      final order = row.read<int>('sort_order');
      (flowSongsByFlow[flowId] ??= <String>[]).add(songId);
      if (order == 0) masterByFlow[flowId] = songId;
    }
    final expansionByMaster = <String, List<String>>{};
    for (final entry in flowSongsByFlow.entries) {
      final master = masterByFlow[entry.key];
      if (master != null && entry.value.isNotEmpty) {
        expansionByMaster[master] = List<String>.unmodifiable(entry.value);
      }
    }

    final expanded = <String>[];
    var remappedStartIndex = 0;
    final normalizedStartIndex = startIndex.clamp(0, normalized.length - 1);
    for (var i = 0; i < normalized.length; i++) {
      if (i == normalizedStartIndex) {
        remappedStartIndex = expanded.length;
      }
      final id = normalized[i];
      expanded.addAll(expansionByMaster[id] ?? <String>[id]);
    }
    return MatchFlowExpansionResult(
      songIds: List<String>.unmodifiable(expanded),
      startIndex: remappedStartIndex.clamp(0, expanded.length - 1),
    );
  }

  List<MatchFlowWithSongs> _mapFlowRows(List<TypedResult> rows) {
    final flows = <String, MatchFlowsTableData>{};
    final songs = <String, List<MatchFlowSongEntry>>{};
    for (final row in rows) {
      final flow = row.readTable(matchFlowsTable);
      flows[flow.id] = flow;
      final link = row.readTableOrNull(matchFlowSongsTable);
      if (link == null) continue;
      (songs[flow.id] ??= <MatchFlowSongEntry>[]).add(
        MatchFlowSongEntry(link: link, song: row.readTableOrNull(songsTable)),
      );
    }
    return flows.values
        .map(
          (flow) => MatchFlowWithSongs(
            flow: flow,
            songs: List<MatchFlowSongEntry>.unmodifiable(
              songs[flow.id] ?? const <MatchFlowSongEntry>[],
            ),
          ),
        )
        .toList(growable: false);
  }

  String _normalizedName(String? name) {
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? defaultFlowName : trimmed;
  }

  Future<void> _ensureFlowExists(String flowId) async {
    final flow =
        await (select(matchFlowsTable)
              ..where((t) => t.id.equals(flowId))
              ..limit(1))
            .getSingleOrNull();
    if (flow == null) {
      throw const MatchFlowException(MatchFlowFailure.flowMissing);
    }
  }

  Future<void> _updateFlow(
    String flowId,
    MatchFlowsTableCompanion companion,
  ) async {
    await (update(
      matchFlowsTable,
    )..where((t) => t.id.equals(flowId))).write(companion);
  }

  Future<void> _touchFlow(String flowId, DateTime now) {
    return _updateFlow(flowId, MatchFlowsTableCompanion(updatedAt: Value(now)));
  }

  Future<List<MatchFlowSongsTableData>> _orderedLinks(String flowId) {
    return (select(matchFlowSongsTable)
          ..where((t) => t.flowId.equals(flowId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.songId),
          ]))
        .get();
  }

  Future<void> _ensureMasterAvailable(
    String songId, {
    required String excludingFlowId,
  }) async {
    final conflict =
        await (select(matchFlowSongsTable)
              ..where(
                (t) =>
                    t.songId.equals(songId) &
                    t.sortOrder.equals(0) &
                    t.flowId.equals(excludingFlowId).not(),
              )
              ..limit(1))
            .getSingleOrNull();
    if (conflict != null) {
      throw const MatchFlowException(MatchFlowFailure.masterInAnotherFlow);
    }
  }

  Future<void> _writeOrder(
    String flowId,
    List<MatchFlowSongsTableData> links,
  ) async {
    for (var i = 0; i < links.length; i++) {
      await (update(matchFlowSongsTable)..where(
            (t) => t.flowId.equals(flowId) & t.songId.equals(links[i].songId),
          ))
          .write(MatchFlowSongsTableCompanion(sortOrder: Value(-i - 1)));
    }
    for (var i = 0; i < links.length; i++) {
      await (update(matchFlowSongsTable)..where(
            (t) => t.flowId.equals(flowId) & t.songId.equals(links[i].songId),
          ))
          .write(MatchFlowSongsTableCompanion(sortOrder: Value(i)));
    }
  }
}
