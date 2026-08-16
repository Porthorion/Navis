import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/features/match_flow/presentation/match_flow_error_message.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

class MatchFlowSongSearchScreen extends ConsumerStatefulWidget {
  const MatchFlowSongSearchScreen({required this.flowId, super.key});

  final String flowId;

  @override
  ConsumerState<MatchFlowSongSearchScreen> createState() =>
      _MatchFlowSongSearchScreenState();
}

class _MatchFlowSongSearchScreenState
    extends ConsumerState<MatchFlowSongSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  Future<List<SongsTableData>>? _results;

  @override
  void initState() {
    super.initState();
    _results = _load('');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.matchFlowAddSongTitle)),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(16),
            child: SearchBar(
              controller: _controller,
              hintText: l10n.matchFlowSearchHint,
              leading: const Icon(Icons.search),
              onChanged: _onQueryChanged,
            ),
          ),
          Expanded(
            child: FutureBuilder<List<SongsTableData>>(
              future: _results,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return ErrorState(
                    title: l10n.matchFlowLoadError,
                    onRetry: _retrySearch,
                  );
                }
                final songs = snapshot.data ?? const <SongsTableData>[];
                if (songs.isEmpty) {
                  return Center(child: Text(l10n.matchFlowNoSearchResults));
                }
                return ListView.builder(
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    return TrackListTile(
                      song: song,
                      showAlbumArt: true,
                      onTap: () => _addSong(song),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _results = _load(value);
      });
    });
  }

  void _retrySearch() {
    setState(() {
      _results = _load(_controller.text);
    });
  }

  Future<List<SongsTableData>> _load(String query) {
    final libraryDao = ref.read(navisDatabaseProvider).libraryDao;
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return libraryDao
          .watchSongsSorted(SongSortOrder.name)
          .first
          .then(
            (songs) => songs.take(80).toList(growable: false),
          );
    }
    return libraryDao.searchCachedSongs(trimmed, limit: 80);
  }

  Future<void> _addSong(SongsTableData song) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref.read(matchFlowDaoProvider).addSong(widget.flowId, song.id);
      if (!mounted) return;
      showAppNotice(
        context,
        message: l10n.matchFlowSongAdded(song.title),
        level: AppNoticeLevel.success,
      );
      Navigator.of(context).pop();
    } on MatchFlowException catch (error) {
      if (!mounted) return;
      showAppNotice(
        context,
        message: matchFlowErrorMessage(l10n, error),
        level: AppNoticeLevel.info,
      );
    } on Object {
      if (!mounted) return;
      showAppNotice(
        context,
        message: l10n.matchFlowSaveError,
        level: AppNoticeLevel.error,
      );
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }
}
