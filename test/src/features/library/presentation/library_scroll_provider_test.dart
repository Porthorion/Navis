import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';

List<LibrarySection> _visible(
  List<LibrarySection> order, {
  bool showArtists = true,
  bool showGenres = true,
}) => visibleLibrarySections(
  orderedSections: order,
  showAlbums: true,
  showLiked: true,
  showArtists: showArtists,
  showGenres: showGenres,
  showPlaylists: true,
  showRadio: true,
);

void main() {
  group('Genres library page order', () {
    test('defaults to right after Artists', () {
      expect(sanitizeLibraryPageOrder(null), <LibrarySection>[
        LibrarySection.albums,
        LibrarySection.liked,
        LibrarySection.artists,
        LibrarySection.genres,
        LibrarySection.playlists,
        LibrarySection.radio,
      ]);
    });

    test('a saved order without genres gets it right after Artists', () {
      final order = sanitizeLibraryPageOrder(<String>[
        'radio',
        'artists',
        'albums',
        'playlists',
        'liked',
      ]);
      expect(order, <LibrarySection>[
        LibrarySection.radio,
        LibrarySection.artists,
        LibrarySection.genres,
        LibrarySection.albums,
        LibrarySection.playlists,
        LibrarySection.liked,
      ]);
    });

    test('Genres takes the slot of a hidden Artists page', () {
      final order = sanitizeLibraryPageOrder(<String>[
        'albums',
        'artists',
        'liked',
        'playlists',
        'radio',
      ]);
      expect(_visible(order, showArtists: false), <LibrarySection>[
        LibrarySection.albums,
        LibrarySection.genres,
        LibrarySection.liked,
        LibrarySection.playlists,
        LibrarySection.radio,
      ]);
    });

    test('a saved order that already places genres keeps it', () {
      final saved = <String>[
        'genres',
        'albums',
        'liked',
        'artists',
        'playlists',
        'radio',
      ];
      expect(
        sanitizeLibraryPageOrder(saved).map((section) => section.name),
        saved,
      );
    });

    test('a hidden Genres page leaves the visible sections', () {
      expect(
        _visible(sanitizeLibraryPageOrder(null), showGenres: false),
        isNot(contains(LibrarySection.genres)),
      );
    });
  });
}
