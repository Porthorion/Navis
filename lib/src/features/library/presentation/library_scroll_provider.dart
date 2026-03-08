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
