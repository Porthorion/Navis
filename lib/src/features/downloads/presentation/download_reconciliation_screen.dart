import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/format_utils.dart';

/// Reviews files Navis could not safely associate with one local song.
/// Mappings only live for this route; leaving it cannot adopt source files.
class DownloadReconciliationScreen extends StatefulWidget {
  const DownloadReconciliationScreen({
    required this.preview,
    required this.automaticallyImported,
    required this.pendingPaths,
    super.key,
  });

  final PermanentDownloadImportPreview preview;
  final int automaticallyImported;
  final Set<String> pendingPaths;

  @override
  State<DownloadReconciliationScreen> createState() =>
      _DownloadReconciliationScreenState();
}

class _DownloadReconciliationScreenState
    extends State<DownloadReconciliationScreen> {
  final Map<String, String> _mappings = <String, String>{};

  List<PermanentDownloadImportItem> get _unresolved => widget.preview.items
      .where(
        (item) =>
            widget.pendingPaths.contains(item.relativePath) &&
            (item.disposition == PermanentDownloadImportDisposition.ambiguous ||
                item.disposition ==
                    PermanentDownloadImportDisposition.unmatched),
      )
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final unresolved = _unresolved;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Download Matches'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(_mappings),
            child: Text('Import ${_mappings.length}'),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${widget.automaticallyImported} clear match(es) imported. '
                  '${unresolved.length} file(s) need your review. '
                  '${widget.preview.profileMismatchCount} protected and '
                  '${widget.preview.inaccessibleCount} inaccessible file(s) remain untouched.',
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: unresolved.length,
              itemBuilder: (context, index) {
                final item = unresolved[index];
                final selected = _mappings[item.relativePath];
                return ListTile(
                  leading: Icon(
                    item.disposition ==
                            PermanentDownloadImportDisposition.ambiguous
                        ? Icons.account_tree_outlined
                        : Icons.help_outline,
                  ),
                  title: Text(item.relativePath),
                  subtitle: Text(
                    '${_reason(item)} · ${item.format.toUpperCase()} · ${formatBytes(item.fileSize)}'
                    '${selected == null ? '' : ' · selected'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final song = await Navigator.of(context)
                        .push<SongsTableData>(
                          MaterialPageRoute<SongsTableData>(
                            builder: (_) => _DownloadMatchPicker(item: item),
                          ),
                        );
                    if (song != null && mounted) {
                      setState(() => _mappings[item.relativePath] = song.id);
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _reason(PermanentDownloadImportItem item) =>
      switch (item.matchOrigin) {
        PermanentDownloadMatchOrigin.ambiguous =>
          'More than one library song matches',
        PermanentDownloadMatchOrigin.unmatched => 'No confident local match',
        _ => 'Needs review',
      };
}

class _DownloadMatchPicker extends ConsumerStatefulWidget {
  const _DownloadMatchPicker({required this.item});

  final PermanentDownloadImportItem item;

  @override
  ConsumerState<_DownloadMatchPicker> createState() =>
      _DownloadMatchPickerState();
}

class _DownloadMatchPickerState extends ConsumerState<_DownloadMatchPicker> {
  late final TextEditingController _controller;
  Timer? _debounce;
  late Future<_CandidateResults> _results;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.item.sourceTitle?.isNotEmpty == true
          ? widget.item.sourceTitle!
          : p.basenameWithoutExtension(widget.item.relativePath),
    );
    _results = _search(_controller.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<_CandidateResults> _search(String query) async {
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    final results = await Future.wait<Object>(<Future<Object>>[
      dao.searchDownloadReconciliationCandidates(query),
      dao.getLikedSongIdsForDownloadReconciliation(),
    ]);
    return _CandidateResults(
      songs: results[0] as List<SongsTableData>,
      likedIds: results[1] as Set<String>,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Choose Library Song')),
    body: Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search liked songs and library',
            ),
            onChanged: (value) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 180), () {
                if (mounted) setState(() => _results = _search(value));
              });
            },
          ),
        ),
        Expanded(
          child: FutureBuilder<_CandidateResults>(
            future: _results,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final results = snapshot.data;
              final songs = results?.songs ?? const <SongsTableData>[];
              if (songs.isEmpty)
                return const Center(child: Text('No local songs found.'));
              return ListView.builder(
                itemCount: songs.length,
                itemBuilder: (context, index) {
                  final song = songs[index];
                  final liked = results?.likedIds.contains(song.id) ?? false;
                  return ListTile(
                    leading: SizedBox(
                      width: 48,
                      height: 48,
                      child: CoverArtImage(
                        coverArtId: song.coverArt,
                        size: 80,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    title: Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${song.artistName ?? 'Unknown artist'} · ${song.albumName ?? 'Unknown album'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: liked
                        ? const Icon(Icons.favorite, color: Colors.red)
                        : null,
                    onTap: () => Navigator.of(context).pop(song),
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

class _CandidateResults {
  const _CandidateResults({required this.songs, required this.likedIds});

  final List<SongsTableData> songs;
  final Set<String> likedIds;
}
