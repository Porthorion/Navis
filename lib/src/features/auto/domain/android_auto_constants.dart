/// Shared Android Auto / Android for Cars media constants.
///
/// Keeping platform keys in one place avoids subtle typos in manifest-adjacent
/// browse/search code where Android Auto only sees raw string extras.
library;

abstract final class AndroidAutoConstants {
  static const String contentStyleSupportedKey =
      'android.media.browse.CONTENT_STYLE_SUPPORTED';
  static const String contentStyleBrowsableHintKey =
      'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
  static const String contentStylePlayableHintKey =
      'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
  static const String contentStyleGroupTitleKey =
      'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';
  static const String searchSupportedKey =
      'android.media.browse.SEARCH_SUPPORTED';

  static const int contentStyleList = 1;
  static const int contentStyleGrid = 2;

  static const String mediaFocusKey = 'android.intent.extra.focus';
  static const String mediaArtistKey = 'android.intent.extra.artist';
  static const String mediaAlbumKey = 'android.intent.extra.album';
  static const String mediaGenreKey = 'android.intent.extra.genre';
  static const String mediaPlaylistKey = 'android.intent.extra.playlist';
  static const String mediaTitleKey = 'android.intent.extra.title';

  static const String mediaFocusArtist = 'vnd.android.cursor.item/artist';
  static const String mediaFocusAlbum = 'vnd.android.cursor.item/album';
  static const String mediaFocusSong = 'vnd.android.cursor.item/audio';
  static const String mediaFocusGenre = 'vnd.android.cursor.item/genre';
  static const String mediaFocusPlaylist = 'vnd.android.cursor.item/playlist';

  static const String downloadStatusKey = 'android.media.extra.DOWNLOAD_STATUS';
  static const int downloadStatusNotDownloaded = 0;
  static const int downloadStatusDownloaded = 2;

  static const String isFavoriteKey = 'android.media.extra.IS_FAVORITE';
  static const String isBrowsableKey = 'browsable';
}
