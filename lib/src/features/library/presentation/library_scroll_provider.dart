import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Incremented whenever the user taps the Library nav icon while already on
/// the Library screen. `LibraryScreen` watches this provider and scrolls the
/// active tab back to the top when the value changes.
class _LibraryScrollToTopNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final libraryScrollToTopRequestProvider =
    NotifierProvider<_LibraryScrollToTopNotifier, int>(
      _LibraryScrollToTopNotifier.new,
    );

enum LibrarySection {
  albums,
  liked,
  artists,
  playlists,
  radio,
}

const List<LibrarySection> defaultLibraryPageOrder = <LibrarySection>[
  LibrarySection.albums,
  LibrarySection.liked,
  LibrarySection.artists,
  LibrarySection.playlists,
  LibrarySection.radio,
];

LibrarySection? librarySectionFromId(String id) {
  for (final section in LibrarySection.values) {
    if (section.name == id) {
      return section;
    }
  }
  return null;
}

List<LibrarySection> sanitizeLibraryPageOrder(List<String>? persistedOrder) {
  final seen = <LibrarySection>{};
  final ordered = <LibrarySection>[];
  if (persistedOrder != null) {
    for (final id in persistedOrder) {
      final section = librarySectionFromId(id);
      if (section != null && seen.add(section)) {
        ordered.add(section);
      }
    }
  }
  for (final section in defaultLibraryPageOrder) {
    if (seen.add(section)) {
      ordered.add(section);
    }
  }
  return ordered;
}

List<LibrarySection> visibleLibrarySections({
  required List<LibrarySection> orderedSections,
  required bool showAlbums,
  required bool showLiked,
  required bool showArtists,
  required bool showPlaylists,
  required bool showRadio,
}) {
  return orderedSections
      .where((section) {
        return switch (section) {
          LibrarySection.albums => showAlbums,
          LibrarySection.liked => showLiked,
          LibrarySection.artists => showArtists,
          LibrarySection.playlists => showPlaylists,
          LibrarySection.radio => showRadio,
        };
      })
      .toList(growable: false);
}

class _LibrarySectionNotifier extends Notifier<LibrarySection> {
  @override
  LibrarySection build() => LibrarySection.albums;

  void setSection(LibrarySection section) {
    state = section;
  }
}

final librarySectionProvider =
    NotifierProvider<_LibrarySectionNotifier, LibrarySection>(
      _LibrarySectionNotifier.new,
    );

/// Whether a library type-to-filter session is currently active (the overlay
/// text is visible). While `true`, transport shortcuts like space → play/pause
/// should be suppressed to avoid interfering with filter input.
class _LibraryTypeFilterActiveNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  set active(bool value) => state = value;
}

final libraryTypeFilterActiveProvider =
    NotifierProvider<_LibraryTypeFilterActiveNotifier, bool>(
      _LibraryTypeFilterActiveNotifier.new,
    );
