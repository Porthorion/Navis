import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/home/domain/home_section_ids.dart';

void main() {
  // A later default list with two sections the saved lists predate.
  const defaults = <String>['a', 'b', 'new_after_b', 'c', 'd', 'new_last'];

  group('resolveOrder', () {
    test('no saved order is the default order', () {
      expect(HomeSectionIds.resolveOrder(null), HomeSectionIds.defaultOrder);
    });

    test('a new section lands after its default predecessor', () {
      expect(
        HomeSectionIds.resolveOrder(<String>[
          'd',
          'b',
          'a',
          'c',
        ], defaults: defaults),
        <String>['d', 'new_last', 'b', 'new_after_b', 'a', 'c'],
      );
    });

    test('a missing predecessor falls back to the one before it', () {
      expect(
        HomeSectionIds.resolveOrder(<String>['c', 'a'], defaults: defaults),
        // b is missing too: it goes after a, then new_after_b after b, and
        // d after c.
        <String>['c', 'd', 'new_last', 'a', 'b', 'new_after_b'],
      );
    });

    test('a section without a present predecessor goes first', () {
      expect(
        HomeSectionIds.resolveOrder(<String>['d'], defaults: defaults),
        <String>['a', 'b', 'new_after_b', 'c', 'd', 'new_last'],
      );
    });

    test('unknown and repeated ids are dropped', () {
      expect(
        HomeSectionIds.resolveOrder(<String>[
          'b',
          'genres',
          'b',
          'a',
        ], defaults: defaults),
        <String>['b', 'new_after_b', 'c', 'd', 'new_last', 'a'],
      );
    });

    test('New Releases is right under You Might Like by default', () {
      final order = HomeSectionIds.defaultOrder;
      expect(
        order.indexOf(HomeSectionIds.newReleases),
        order.indexOf(HomeSectionIds.randomAlbums) + 1,
      );
    });

    test('a saved order that predates New Releases puts it under You Might '
        'Like', () {
      const saved = <String>[
        HomeSectionIds.recentlyPlayed,
        HomeSectionIds.randomAlbums,
        HomeSectionIds.recentlyAdded,
        HomeSectionIds.likedTracks,
      ];
      final resolved = HomeSectionIds.resolveOrder(saved);
      expect(
        resolved.indexOf(HomeSectionIds.newReleases),
        resolved.indexOf(HomeSectionIds.randomAlbums) + 1,
      );
      // The user's own order of the rest is untouched.
      expect(resolved.where(saved.contains).toList(), saved);
    });

    test('New Releases follows You Might Like wherever the user moved it', () {
      const saved = <String>[
        HomeSectionIds.recentlyAdded,
        HomeSectionIds.likedTracks,
        HomeSectionIds.recentlyPlayed,
        HomeSectionIds.randomAlbums,
      ];
      final resolved = HomeSectionIds.resolveOrder(saved);
      expect(
        resolved.indexOf(HomeSectionIds.newReleases),
        resolved.indexOf(HomeSectionIds.randomAlbums) + 1,
      );
    });

    test('a user who already placed New Releases keeps it there', () {
      const saved = <String>[
        HomeSectionIds.randomAlbums,
        HomeSectionIds.recentlyLikedAlbums,
        HomeSectionIds.likedTracks,
        HomeSectionIds.recentlyAdded,
        HomeSectionIds.randomAlbumList,
        HomeSectionIds.recentlyPlayed,
        HomeSectionIds.mostPlayed,
        HomeSectionIds.recentlyPlayedTracks,
        HomeSectionIds.frequentAlbums,
        HomeSectionIds.newReleases,
      ];
      expect(HomeSectionIds.resolveOrder(saved), saved);
    });

    test('Random Albums follows Recently Added by default', () {
      final order = HomeSectionIds.defaultOrder;
      expect(
        order.indexOf(HomeSectionIds.randomAlbumList),
        order.indexOf(HomeSectionIds.recentlyAdded) + 1,
      );
    });

    test('a saved order that predates Random Albums gets it after Recently '
        'Added', () {
      const saved = <String>[
        HomeSectionIds.recentlyAdded,
        HomeSectionIds.likedTracks,
      ];
      final resolved = HomeSectionIds.resolveOrder(saved);
      expect(
        resolved.indexOf(HomeSectionIds.randomAlbumList),
        resolved.indexOf(HomeSectionIds.recentlyAdded) + 1,
      );
    });

    test('a saved order of the shipped sections keeps every default', () {
      final saved = HomeSectionIds.defaultOrder.reversed.toList();
      final resolved = HomeSectionIds.resolveOrder(saved);
      expect(resolved.toSet(), HomeSectionIds.defaultOrder.toSet());
      expect(resolved.first, saved.first);
    });
  });

  group('resolveHidden', () {
    test('no saved list hides the default hidden sections', () {
      expect(HomeSectionIds.resolveHidden(null), HomeSectionIds.defaultHidden);
    });

    test('the saved list decides every section the user has seen', () {
      expect(
        HomeSectionIds.resolveHidden(<String>[
          HomeSectionIds.likedTracks,
        ], persistedOrder: HomeSectionIds.defaultOrder),
        <String>[HomeSectionIds.likedTracks],
      );
    });

    test('a new section hidden by default stays hidden until seen', () {
      const hiddenByDefault = <String>['new_last'];
      expect(
        HomeSectionIds.resolveHidden(
          <String>['a'],
          persistedOrder: <String>['a', 'b', 'c', 'd'],
          defaults: defaults,
          hiddenByDefault: hiddenByDefault,
        ),
        <String>['a', 'new_last'],
      );
      // Once the order was saved with it, the saved list decides.
      expect(
        HomeSectionIds.resolveHidden(
          <String>['a'],
          persistedOrder: defaults,
          defaults: defaults,
          hiddenByDefault: hiddenByDefault,
        ),
        <String>['a'],
      );
    });

    test('Random Albums is hidden by default and for existing users', () {
      expect(
        HomeSectionIds.defaultHidden,
        contains(HomeSectionIds.randomAlbumList),
      );
      // Saved lists that predate the section.
      expect(
        HomeSectionIds.resolveHidden(
          <String>[HomeSectionIds.likedTracks],
          persistedOrder: <String>[
            HomeSectionIds.recentlyAdded,
            HomeSectionIds.likedTracks,
          ],
        ),
        contains(HomeSectionIds.randomAlbumList),
      );
    });

    test('a new section visible by default shows for a saved list', () {
      expect(
        HomeSectionIds.resolveHidden(
          <String>['a'],
          defaults: defaults,
          hiddenByDefault: const <String>[],
        ),
        <String>['a'],
      );
    });

    test('unknown ids are dropped', () {
      expect(
        HomeSectionIds.resolveHidden(<String>[
          'genres',
          HomeSectionIds.mostPlayed,
        ]),
        <String>[HomeSectionIds.mostPlayed, HomeSectionIds.randomAlbumList],
      );
    });
  });
}
