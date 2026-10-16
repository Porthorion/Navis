import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/domain/playlist_ownership.dart';

void main() {
  const base = PlaylistsTableData(isLocal: false, id: 'p', name: 'Playlist');
  for (final (label, playlist, me, editable, own)
      in <(String, PlaylistsTableData, String?, bool, bool)>[
        (
          'local overrides readonly and owner',
          base.copyWith(
            isLocal: true,
            readOnly: const Value(true),
            owner: const Value('bob'),
          ),
          'alice',
          true,
          true,
        ),
        (
          'readonly blocks own smart playlist',
          base.copyWith(
            readOnly: const Value(true),
            owner: const Value('alice'),
          ),
          'alice',
          false,
          false,
        ),
        (
          'readonly blocks unknown username',
          base.copyWith(readOnly: const Value(true)),
          null,
          false,
          false,
        ),
        (
          'other owner',
          base.copyWith(owner: const Value('BOB')),
          'alice',
          false,
          false,
        ),
        (
          'owner matches ignoring case',
          base.copyWith(owner: const Value('ALICE')),
          'Alice',
          true,
          true,
        ),
        ('missing owner', base, 'alice', true, true),
        (
          'missing username',
          base.copyWith(owner: const Value('bob')),
          null,
          true,
          true,
        ),
        ('both missing', base, null, true, true),
        (
          'explicitly editable own playlist',
          base.copyWith(
            owner: const Value('alice'),
            readOnly: const Value(false),
          ),
          'alice',
          true,
          true,
        ),
        (
          'import comment excludes ownership',
          base.copyWith(comment: const Value("Auto-imported from 'mix.m3u'")),
          'alice',
          true,
          false,
        ),
        (
          'import marker must be the prefix',
          base.copyWith(
            comment: const Value("Notes: Auto-imported from 'mix.m3u'"),
          ),
          'alice',
          true,
          true,
        ),
      ]) {
    test(label, () {
      expect(canEditPlaylist(playlist, me), editable);
      expect(isOwnPlaylist(playlist, me), own);
    });
  }
}
