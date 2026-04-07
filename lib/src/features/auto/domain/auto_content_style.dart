/// Android Auto content-style hint extras.
///
/// These key/value pairs are attached to parent [MediaItem] extras so that
/// Android Auto can pick the right layout (grid vs. list) for children.
///
/// See https://developer.android.com/training/cars/media/create-media-browser/content-style
library;

/// Keys used in [MediaItem.extras] to hint at browsable/playable presentation.
abstract final class AutoContentStyle {
  /// Key for the browsable-items content style (grid vs list).
  static const String browsableHintKey =
      'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';

  /// Key for the playable-items content style (grid vs list).
  static const String playableHintKey =
      'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';

  /// Supported hint key telling AA that this parent supports content style.
  static const String supportedKey =
      'android.media.browse.CONTENT_STYLE_SUPPORTED';

  /// Present items as a grid (album art focused).
  static const int grid = 2;

  /// Present items as a list (text focused).
  static const int list = 1;

  /// Extras map that requests grid layout for browsable children and list
  /// layout for playable children.  Suitable for album listings.
  static const Map<String, dynamic> gridBrowsableListPlayable = {
    supportedKey: true,
    browsableHintKey: grid,
    playableHintKey: list,
  };

  /// Extras map that requests list layout for both browsable and playable
  /// children.  Suitable for artist and playlist listings.
  static const Map<String, dynamic> listBrowsableListPlayable = {
    supportedKey: true,
    browsableHintKey: list,
    playableHintKey: list,
  };
}
