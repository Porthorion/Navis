# Share System — Implementation Plan

## Overview

**Issue:** [#15 — Share System](https://git.porthorion.com/khalifa/Navis/issues/15)

Navis is a multi-platform (Android, iOS, macOS, Linux, Windows) Subsonic/OpenSubsonic music client built with Flutter. Each user connects to their own self-hosted Subsonic server with unique content libraries. There is no central Navis infrastructure.

### Problem

Users have no way to share music they're listening to. There are no share buttons, no deep linking, no URI scheme registration, and no Subsonic share API integration.

### Solution

A layered share system that:

1. **Generates a visual share card** — a rendered PNG image (cover art + metadata) that displays as an inline preview when pasted into chat apps
2. **Includes a `navis://` deep link** — recipients with Navis installed tap to open the content on their own server
3. **Falls back to search** — if the content doesn't exist on the recipient's server, opens the search screen with the name pre-filled
4. **Optionally includes a public streaming URL** — via the Subsonic `createShare` API (when the server supports it)

### Share UX

Two actions available from context menus and detail screen app bars:

- **Share** — opens the system share sheet (WhatsApp, Telegram, etc.) with the share card image + formatted text
- **Copy Link** — copies the `navis://` URI + metadata text to clipboard

### Shareable Content Types

Songs, albums, artists, and playlists.

---

## Architecture

### New Feature Module

```
lib/src/features/sharing/
├── data/
│   ├── share_card_renderer.dart    # Canvas-based PNG generation
│   └── share_service.dart          # Orchestrates image + URI + share sheet
├── domain/
│   └── share_content.dart          # Freezed union model + URI serialization
└── presentation/
    ├── share_actions.dart          # Top-level functions called from menus/buttons
    ├── share_providers.dart        # Riverpod providers
    └── deep_link_handler.dart      # URI parsing + search + navigation
```

### New API Model

```
lib/src/api/models/share_info.dart  # Subsonic createShare response model
```

### Data Flow

```
User taps Share
  → ShareActions builds ShareContent from entity data
  → ShareService fetches cover art bytes from flutter_cache_manager
  → ShareCardRenderer draws PNG via dart:ui Canvas (1200×630)
  → ShareService writes PNG to temp file
  → ShareService optionally calls SubsonicApiClient.createShare()
  → ShareService calls Share.shareXFiles() (share_plus) OR Clipboard.setData()

Recipient taps navis:// link
  → OS launches Navis via registered URI scheme
  → AppLinks captures URI (initial or stream)
  → DeepLinkHandler parses ShareContent.fromUri()
  → NavService.goToSearch() pre-fills search query and navigates to /search
  → User sees matching results from their own server
```

---

## Implementation Phases

### Phase 1: Dependencies & Domain Model

#### 1.1 Add dependencies

**File:** `pubspec.yaml`

Add under `dependencies`:
```yaml
share_plus: ^10.1.0
app_links: ^6.4.0
```

Run `flutter pub get`.

#### 1.2 Create the share content model

**File:** `lib/src/features/sharing/domain/share_content.dart`

Create a Freezed union type with four variants:

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'share_content.freezed.dart';

@freezed
sealed class ShareContent with _$ShareContent {
  const ShareContent._();

  const factory ShareContent.song({
    required String title,
    required String artist,
    String? album,
    String? coverArtId,
  }) = ShareSong;

  const factory ShareContent.album({
    required String name,
    required String artist,
    String? coverArtId,
  }) = ShareAlbum;

  const factory ShareContent.artist({
    required String name,
    String? coverArtId,
  }) = ShareArtist;

  const factory ShareContent.playlist({
    required String name,
    String? owner,
    String? coverArtId,
  }) = SharePlaylist;

  /// Builds a navis:// URI for deep linking.
  ///
  /// Examples:
  ///   navis://song?title=Bohemian+Rhapsody&artist=Queen&album=A+Night+at+the+Opera
  ///   navis://album?name=OK+Computer&artist=Radiohead
  ///   navis://artist?name=Pink+Floyd
  ///   navis://playlist?name=Chill+Vibes
  Uri toUri() {
    return switch (this) {
      ShareSong(:final title, :final artist, :final album) => Uri(
          scheme: 'navis',
          host: 'song',
          queryParameters: {
            'title': title,
            'artist': artist,
            if (album != null) 'album': album,
          },
        ),
      ShareAlbum(:final name, :final artist) => Uri(
          scheme: 'navis',
          host: 'album',
          queryParameters: {'name': name, 'artist': artist},
        ),
      ShareArtist(:final name) => Uri(
          scheme: 'navis',
          host: 'artist',
          queryParameters: {'name': name},
        ),
      SharePlaylist(:final name, :final owner) => Uri(
          scheme: 'navis',
          host: 'playlist',
          queryParameters: {
            'name': name,
            if (owner != null) 'owner': owner,
          },
        ),
    };
  }

  /// Parses a navis:// URI back into a ShareContent.
  /// Returns null if the URI is invalid or not a navis:// scheme.
  static ShareContent? fromUri(Uri uri) {
    if (uri.scheme != 'navis') return null;
    final params = uri.queryParameters;

    return switch (uri.host) {
      'song' when params['title'] != null && params['artist'] != null =>
        ShareContent.song(
          title: params['title']!,
          artist: params['artist']!,
          album: params['album'],
        ),
      'album' when params['name'] != null && params['artist'] != null =>
        ShareContent.album(
          name: params['name']!,
          artist: params['artist']!,
        ),
      'artist' when params['name'] != null =>
        ShareContent.artist(name: params['name']!),
      'playlist' when params['name'] != null =>
        ShareContent.playlist(name: params['name']!, owner: params['owner']),
      _ => null,
    };
  }

  /// Human-readable formatted text for sharing.
  String toShareText({String? publicUrl}) {
    final buffer = StringBuffer();

    switch (this) {
      case ShareSong(:final title, :final artist, :final album):
        buffer.writeln('$title — $artist');
        if (album != null) buffer.writeln(album);
      case ShareAlbum(:final name, :final artist):
        buffer.writeln('$name — $artist');
      case ShareArtist(:final name):
        buffer.writeln(name);
      case SharePlaylist(:final name):
        buffer.writeln(name);
    }

    buffer.writeln();
    if (publicUrl != null) {
      buffer.writeln('Listen: $publicUrl');
      buffer.writeln();
    }
    buffer.writeln('Open in Navis: ${toUri()}');

    return buffer.toString().trimRight();
  }

  /// Search query for finding this content on the recipient's server.
  String get searchQuery => switch (this) {
        ShareSong(:final title, :final artist) => '$artist $title',
        ShareAlbum(:final name, :final artist) => '$artist $name',
        ShareArtist(:final name) => name,
        SharePlaylist(:final name) => name,
      };
}
```

#### 1.3 Run code generation

```bash
make gen
# or: dart run build_runner build --delete-conflicting-outputs
```

---

### Phase 2: Subsonic `createShare` API

#### 2.1 Create ShareInfo model

**File:** `lib/src/api/models/share_info.dart`

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'share_info.freezed.dart';
part 'share_info.g.dart';

@freezed
abstract class ShareInfo with _$ShareInfo {
  const factory ShareInfo({
    required String id,
    String? url,
    String? description,
    DateTime? expires,
    DateTime? created,
  }) = _ShareInfo;

  factory ShareInfo.fromJson(Map<String, dynamic> json) =>
      _$ShareInfoFromJson(json);
}
```

#### 2.2 Register the model export

**File:** `lib/src/api/models/models.dart`

Add:
```dart
export 'share_info.dart';
```

#### 2.3 Add `createShare` method to the API client

**File:** `lib/src/api/subsonic_api_client.dart`

Add this method to the `SubsonicApiClient` class. Place it near the other action methods (star, unstar, setRating). Follow the existing `_readRoot()` → parse → return pattern:

```dart
/// Creates a public URL for sharing a media item.
///
/// Returns the share info including the public URL, or `null` if the
/// server does not support sharing.
///
/// See: https://opensubsonic.netlify.app/docs/endpoints/createshare/
Future<ShareInfo?> createShare(
  String id, {
  String? description,
  CancelToken? cancelToken,
}) async {
  try {
    final root = await _readRoot(
      '/rest/createShare.view',
      query: <String, dynamic>{
        'id': id,
        if (description != null) 'description': description,
      },
      cancelToken: cancelToken,
    );
    final shares = _asMapList(_asMap(root['shares'])['share']);
    if (shares.isEmpty) return null;
    return ShareInfo.fromJson(shares.first);
  } on SubsonicException {
    // Server does not support sharing — return null silently.
    return null;
  }
}
```

**Import required:** Add `import 'models/share_info.dart';` if not already covered by the models barrel export.

#### 2.4 Run code generation again

```bash
make gen
```

---

### Phase 3: Share Card Renderer

#### 3.1 Implement canvas-based PNG generation

**File:** `lib/src/features/sharing/data/share_card_renderer.dart`

This renders a 1200×630 PNG share card using `dart:ui` (no widget tree needed).

**Design specification:**
- **Dimensions:** 1200×630 pixels (standard Open Graph image ratio)
- **Background:** dark gradient from `#1a1a2e` to `#16213e`
- **Left section (~45%):** cover art displayed as a square with rounded corners (~500×500), vertically centered, with 65px left margin
- **Right section (~55%):** text content with 40px padding from cover art edge
  - Content type label (e.g., "SONG", "ALBUM") in small caps, muted color
  - Title in large bold white text (max 2 lines, ellipsis overflow)
  - Artist name in medium semi-transparent white (max 1 line)
  - Album name (songs only) in smaller semi-transparent white (max 1 line)
- **Bottom-right corner:** Navis logo icon (loaded from `lib/src/icon/Navis_Icon_Dark.png` via `rootBundle`), ~40×40, semi-transparent
- **Missing cover art fallback:** draw a music note icon (Unicode ♪) or a filled rounded rect with a subtle gradient

**Key implementation details:**

```dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';

class ShareCardRenderer {
  static const _width = 1200.0;
  static const _height = 630.0;

  /// Renders a share card PNG image.
  ///
  /// [coverArtBytes] — raw PNG/JPEG bytes of the cover art (nullable).
  /// [title] — primary text (song title, album name, artist name, etc.).
  /// [subtitle] — secondary text (artist name for songs/albums, null for artists).
  /// [tertiaryText] — tertiary text (album name for songs, null otherwise).
  /// [typeLabel] — content type label ("SONG", "ALBUM", "ARTIST", "PLAYLIST").
  static Future<Uint8List> render({
    Uint8List? coverArtBytes,
    required String title,
    String? subtitle,
    String? tertiaryText,
    required String typeLabel,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // 1. Draw background gradient
    _drawBackground(canvas);

    // 2. Draw cover art (or placeholder)
    if (coverArtBytes != null) {
      await _drawCoverArt(canvas, coverArtBytes);
    } else {
      _drawCoverArtPlaceholder(canvas);
    }

    // 3. Draw text content
    _drawText(canvas, title: title, subtitle: subtitle,
              tertiaryText: tertiaryText, typeLabel: typeLabel);

    // 4. Draw Navis logo
    await _drawNavisLogo(canvas);

    // 5. Convert to PNG
    final picture = recorder.endRecording();
    final image = await picture.toImage(_width.toInt(), _height.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  // ... private drawing methods using Canvas API and TextPainter ...
}
```

**Text rendering notes:**
- Use `ui.ParagraphBuilder` with `ui.ParagraphStyle` and `ui.TextStyle` (from `dart:ui`, NOT `package:flutter/material.dart`)
- Handle text overflow by setting `maxLines` and `ellipsis` on the `ParagraphStyle`
- For the Navis logo, load from rootBundle: `rootBundle.load('lib/src/icon/Navis_Icon_Dark.png')`
- For cover art decoding, use `ui.decodeImageFromList()` (async, wraps in a `Completer`)

---

### Phase 4: Share Service

#### 4.1 Orchestration service

**File:** `lib/src/features/sharing/data/share_service.dart`

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/sharing/data/share_card_renderer.dart';
import 'package:navis/src/features/sharing/domain/share_content.dart';

class ShareService {
  ShareService({
    required this.apiClient,
    required this.cacheManager,
  });

  final SubsonicApiClient apiClient;
  final BaseCacheManager cacheManager;

  /// Share content via the system share sheet (image + text).
  Future<void> share(ShareContent content, {String? entityId}) async {
    final cardBytes = await _generateCard(content);
    final publicUrl = await _tryCreateShare(entityId);
    final text = content.toShareText(publicUrl: publicUrl);

    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/navis_share_card.png');
    await file.writeAsBytes(cardBytes);

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'image/png')],
      text: text,
    );
  }

  /// Copy the navis:// link text to clipboard.
  Future<void> copyLink(ShareContent content, {String? entityId}) async {
    final publicUrl = await _tryCreateShare(entityId);
    final text = content.toShareText(publicUrl: publicUrl);
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<Uint8List> _generateCard(ShareContent content) async {
    final coverArtBytes = await _fetchCoverArt(content.coverArtId);

    return ShareCardRenderer.render(
      coverArtBytes: coverArtBytes,
      title: switch (content) {
        ShareSong(:final title) => title,
        ShareAlbum(:final name) => name,
        ShareArtist(:final name) => name,
        SharePlaylist(:final name) => name,
      },
      subtitle: switch (content) {
        ShareSong(:final artist) => artist,
        ShareAlbum(:final artist) => artist,
        _ => null,
      },
      tertiaryText: switch (content) {
        ShareSong(:final album) => album,
        _ => null,
      },
      typeLabel: switch (content) {
        ShareSong() => 'SONG',
        ShareAlbum() => 'ALBUM',
        ShareArtist() => 'ARTIST',
        SharePlaylist() => 'PLAYLIST',
      },
    );
  }

  Future<Uint8List?> _fetchCoverArt(String? coverArtId) async {
    if (coverArtId == null) return null;
    try {
      final url = apiClient.getCoverArtUrl(
        id: coverArtId,
        size: kCoverArtStandardSize,
      );
      final fileInfo = await cacheManager.getFileFromCache(url.toString());
      if (fileInfo != null) {
        return fileInfo.file.readAsBytes();
      }
      // If not cached, download fresh
      final file = await cacheManager.getSingleFile(url.toString());
      return file.readAsBytes();
    } catch (_) {
      return null; // Proceed without cover art
    }
  }

  Future<String?> _tryCreateShare(String? entityId) async {
    if (entityId == null) return null;
    try {
      final share = await apiClient.createShare(entityId);
      return share?.url;
    } catch (_) {
      return null; // Server doesn't support sharing
    }
  }
}
```

**Note on `coverArtId`:** The `ShareContent` model includes an optional `coverArtId` field. This is the Subsonic cover art ID from the entity's `coverArt` field. The `_fetchCoverArt` method uses the existing `getCoverArtUrl()` from `SubsonicApiClient` and the `coverArtCacheKey`-based `BaseCacheManager` to fetch the image bytes.

#### 4.2 Riverpod provider

**File:** `lib/src/features/sharing/presentation/share_providers.dart`

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/sharing/data/share_service.dart';
import 'package:navis/src/providers/app_providers.dart';

final shareServiceProvider = Provider<ShareService>((ref) {
  // coverArtCacheManagerProvider is a StreamProvider<CacheManager>.
  // Use .asData?.value to get the current cache manager, falling back to
  // the module-level defaultCoverArtCacheManager if the stream hasn't
  // emitted yet.
  final cacheManager =
      ref.watch(coverArtCacheManagerProvider).asData?.value ??
      defaultCoverArtCacheManager;
  return ShareService(
    apiClient: ref.watch(subsonicApiProvider),
    cacheManager: cacheManager,
  );
});
```

**Note:** `coverArtCacheManagerProvider` is a `StreamProvider<CacheManager>` defined in `cover_art_image.dart:145`. It rebuilds when the user changes the cover art cache size setting. The fallback `defaultCoverArtCacheManager` is a module-level constant at `cover_art_image.dart:139`.

---

### Phase 5: UI Integration

#### 5.1 Top-level share action functions

**File:** `lib/src/features/sharing/presentation/share_actions.dart`

These are the public API that context menus and buttons call. Each function constructs a `ShareContent`, invokes the share service, and shows feedback via SnackBar.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/sharing/domain/share_content.dart';
import 'package:navis/src/features/sharing/presentation/share_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Shares a song via the system share sheet.
Future<void> shareSong(
  BuildContext context,
  WidgetRef ref,
  SongsTableData song, {
  bool copyOnly = false,
}) async {
  final content = ShareContent.song(
    title: song.title,
    artist: song.artistName ?? 'Unknown Artist',
    album: song.albumName,
    coverArtId: song.coverArt,
  );
  await _executeShare(context, ref, content,
      entityId: song.id, copyOnly: copyOnly);
}

/// Shares an album. Fetches album data from the provider first.
Future<void> shareAlbum(
  BuildContext context,
  WidgetRef ref,
  String albumId, {
  bool copyOnly = false,
}) async {
  final album = await ref.read(albumProvider(albumId).future);
  if (album == null) return;
  final content = ShareContent.album(
    name: album.album.name,
    artist: album.album.artistName ?? 'Unknown Artist',
    coverArtId: album.album.coverArt,
  );
  await _executeShare(context, ref, content,
      entityId: albumId, copyOnly: copyOnly);
}

/// Shares an artist. Fetches artist data from the provider first.
Future<void> shareArtist(
  BuildContext context,
  WidgetRef ref,
  String artistId, {
  bool copyOnly = false,
}) async {
  final api = ref.read(subsonicApiProvider);
  final artist = await api.getArtist(artistId);
  final content = ShareContent.artist(
    name: artist.name,
    coverArtId: artist.coverArt,
  );
  await _executeShare(context, ref, content,
      entityId: artistId, copyOnly: copyOnly);
}

/// Shares a playlist. Fetches playlist data from the provider first.
Future<void> sharePlaylist(
  BuildContext context,
  WidgetRef ref,
  String playlistId, {
  bool copyOnly = false,
}) async {
  final api = ref.read(subsonicApiProvider);
  final playlist = await api.getPlaylist(playlistId);
  final content = ShareContent.playlist(
    name: playlist.name,
    owner: playlist.owner,
    coverArtId: playlist.coverArt,
  );
  await _executeShare(context, ref, content,
      entityId: playlistId, copyOnly: copyOnly);
}

Future<void> _executeShare(
  BuildContext context,
  WidgetRef ref,
  ShareContent content, {
  String? entityId,
  required bool copyOnly,
}) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    final service = ref.read(shareServiceProvider);
    if (copyOnly) {
      await service.copyLink(content, entityId: entityId);
      if (context.mounted) {
        showAppNotice(context, message: l10n.linkCopied);
      }
    } else {
      await service.share(content, entityId: entityId);
    }
  } catch (e) {
    if (context.mounted) {
      showAppNotice(context, message: l10n.shareError);
    }
  }
}
```

**Important:** Verify the exact provider names and data access patterns by reading the actual provider definitions. The `albumProvider` is referenced in `album_context_menu.dart` — use the same one. For artist and playlist, check if equivalent providers exist or use the API client directly.

#### 5.2 Add Share and Copy Link to song context menu

**File:** `lib/src/common_widgets/song_context_menu.dart`

**Changes:**

1. Add to the `_SongContextAction` enum (find it in the file):
```dart
share,
copyLink,
```

2. Add two new `ListTile` items to the mobile bottom sheet, **after** the "Add to Playlist" item and **before** the "Download" item:
```dart
ListTile(
  leading: const Icon(Icons.share_outlined),
  title: Text(l10n.shareAction),
  onTap: () {
    Navigator.pop(sheetContext);
    shareSong(context, ref, song);
  },
),
ListTile(
  leading: const Icon(Icons.link_outlined),
  title: Text(l10n.copyLinkAction),
  onTap: () {
    Navigator.pop(sheetContext);
    shareSong(context, ref, song, copyOnly: true);
  },
),
```

3. Add corresponding `PopupMenuItem` entries to the desktop popup menu (same position). **Note:** Desktop popup menus use `Text(...)` children directly (no `ListTile` wrapper, no icons):
```dart
PopupMenuItem<_SongContextAction>(
  value: _SongContextAction.share,
  child: Text(l10n.shareAction),
),
PopupMenuItem<_SongContextAction>(
  value: _SongContextAction.copyLink,
  child: Text(l10n.copyLinkAction),
),
```

4. Add cases to the desktop action handler switch:
```dart
case _SongContextAction.share:
  shareSong(context, ref, song);
case _SongContextAction.copyLink:
  shareSong(context, ref, song, copyOnly: true);
```

5. Add import at top of file:
```dart
import 'package:navis/src/features/sharing/presentation/share_actions.dart';
```

#### 5.3 Add Share and Copy Link to album context menu

**File:** `lib/src/common_widgets/album_context_menu.dart`

Same pattern as song context menu:

1. Add `share` and `copyLink` to the `_AlbumContextAction` enum
2. Add `ListTile` items after "Like/Unlike", before "Download" (mobile)
3. Add `PopupMenuItem` items (desktop)
4. Add switch cases calling `shareAlbum(context, ref, albumId)` and `shareAlbum(context, ref, albumId, copyOnly: true)`
5. Add the import for `share_actions.dart`

#### 5.4 Add share button to album detail screen

**File:** `lib/src/features/library/presentation/album_detail_screen.dart`

Add an `IconButton` to the `SliverAppBar` or `AppBar` actions list:

```dart
IconButton(
  icon: const Icon(Icons.share_outlined),
  tooltip: l10n.shareAction,
  onPressed: () => shareAlbum(context, ref, albumId),
),
```

The album ID and data are already available in the screen's build method.

#### 5.5 Add share button to artist detail screen

**File:** `lib/src/features/library/presentation/artist_detail_screen.dart`

Add share `IconButton` to the `AppBar` actions. The artist ID is available as a route parameter.

#### 5.6 Add share button to playlist detail screen

**File:** `lib/src/features/playlists/presentation/playlist_detail_screen.dart`

Add share `IconButton` to the `AppBar` actions. The playlist ID is available as a route parameter.

#### 5.7 Add share button to now playing screen

**File:** `lib/src/features/player/presentation/now_playing_screen.dart`

Add a share `IconButton` to the player controls area. The current song data is available from the `playbackSnapshotProvider`. Place it near existing action buttons (like/star, queue, etc.).

```dart
IconButton(
  icon: const Icon(Icons.share_outlined),
  tooltip: l10n.shareAction,
  onPressed: () {
    final song = snapshot.currentSong;
    if (song != null) shareSong(context, ref, song);
  },
),
```

---

### Phase 6: Deep Link Reception

#### 6.1 Android configuration

**File:** `android/app/src/main/AndroidManifest.xml`

Add this `<intent-filter>` inside the main `<activity>` block (the one with `android.intent.action.MAIN`), as a sibling to the existing `<intent-filter>`:

```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data android:scheme="navis"/>
</intent-filter>
```

#### 6.2 iOS configuration

**File:** `ios/Runner/Info.plist`

Add inside the top-level `<dict>`, before `</dict>`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>navis</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.navis.app</string>
    </dict>
</array>
```

#### 6.3 macOS configuration

**File:** `macos/Runner/Info.plist`

Add the same `CFBundleURLTypes` block as iOS.

#### 6.4 Linux configuration

**File:** `linux/packaging/com.navis.app.navis.desktop`

Add `x-scheme-handler/navis;` to the end of the `MimeType` line:

```
MimeType=audio/mpeg;audio/ogg;audio/flac;audio/x-flac;audio/wav;audio/aac;audio/x-m4a;x-scheme-handler/navis;
```

The `Exec=navis %U` line already supports URI arguments.

#### 6.5 Windows configuration

The `app_links` package handles Windows URL protocol registration automatically. No manual configuration is needed for the initial implementation. If issues arise, URL protocol registration can be added to the MSIX manifest or NSIS installer.

#### 6.6 Deep link handler

**File:** `lib/src/features/sharing/presentation/deep_link_handler.dart`

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:navis/src/features/sharing/domain/share_content.dart';
import 'package:navis/src/routing/navigation_service.dart';

class DeepLinkHandler {
  /// Handles an incoming navis:// URI.
  ///
  /// Parses the URI into a [ShareContent], then navigates to the search
  /// screen with the content's metadata pre-filled as the search query.
  static void handleUri(BuildContext context, WidgetRef ref, Uri uri) {
    if (uri.scheme != 'navis') return;
    final content = ShareContent.fromUri(uri);
    if (content == null) return;

    // Use the existing NavService to navigate to search with the query
    NavService.goToSearch(context, ref, content.searchQuery);
  }
}
```

**Key existing utility used:** `NavService.goToSearch()` at `lib/src/routing/navigation_service.dart:50` already handles:
- Dismissing overlays and collapsing the player sheet
- Setting the `searchQueryProvider` state
- Navigating to `/search`

#### 6.7 Wire deep link listener in app shell

**File:** `lib/src/routing/app_shell.dart`

In the `AppShell` widget's `initState` (or equivalent lifecycle method), initialize `AppLinks` and listen for incoming URIs:

```dart
import 'package:app_links/app_links.dart';
import 'package:navis/src/features/sharing/presentation/deep_link_handler.dart';

// In initState or equivalent:
late final AppLinks _appLinks;
StreamSubscription<Uri>? _deepLinkSub;

@override
void initState() {
  super.initState();
  _appLinks = AppLinks();

  // Handle links received while app is running
  _deepLinkSub = _appLinks.uriLinkStream.listen((uri) {
    DeepLinkHandler.handleUri(context, ref, uri);
  });

  // Handle cold-start link (app opened via deep link)
  _appLinks.getInitialLink().then((uri) {
    if (uri != null) {
      // Defer until auth is complete — the user must be logged in first
      // Watch serverConfigStateProvider or similar to know when ready
      DeepLinkHandler.handleUri(context, ref, uri);
    }
  });
}

@override
void dispose() {
  _deepLinkSub?.cancel();
  super.dispose();
}
```

**Cold-start handling caveat:** When the app opens from a deep link while not running, the auth state may not be ready. The initial link must be queued and processed after the user is authenticated. Check the existing auth flow in `app_shell.dart` — there is likely already a mechanism that gates UI behind auth (e.g., redirect to login). Store the pending URI and process it after auth completes.

---

### Phase 7: Localization

**File:** `lib/l10n/app_en.arb`

Add these entries (follow the existing JSON key naming pattern in the file):

```json
"shareAction": "Share",
"@shareAction": {"description": "Context menu action to share content via system share sheet"},
"copyLinkAction": "Copy Link",
"@copyLinkAction": {"description": "Context menu action to copy a navis:// deep link to clipboard"},
"linkCopied": "Link copied to clipboard",
"@linkCopied": {"description": "Snackbar message after copying a share link"},
"shareError": "Could not share. Please try again.",
"@shareError": {"description": "Snackbar message when sharing fails"}
```

---

## Files Summary

### New Files to Create

| File | Purpose |
|------|---------|
| `lib/src/features/sharing/domain/share_content.dart` | Freezed union model + URI serialization |
| `lib/src/features/sharing/data/share_card_renderer.dart` | Canvas-based PNG card generation |
| `lib/src/features/sharing/data/share_service.dart` | Orchestrates card rendering, share sheet, clipboard |
| `lib/src/features/sharing/presentation/share_actions.dart` | Public functions called from menus/buttons |
| `lib/src/features/sharing/presentation/share_providers.dart` | Riverpod providers for the share service |
| `lib/src/features/sharing/presentation/deep_link_handler.dart` | Parses incoming navis:// URIs + navigates |
| `lib/src/api/models/share_info.dart` | Subsonic `createShare` response model |

### Existing Files to Modify

| File | Change |
|------|--------|
| `pubspec.yaml` | Add `share_plus`, `app_links` dependencies |
| `lib/src/api/models/models.dart` | Export `share_info.dart` |
| `lib/src/api/subsonic_api_client.dart` | Add `createShare()` method |
| `lib/src/common_widgets/song_context_menu.dart` | Add Share + Copy Link menu items |
| `lib/src/common_widgets/album_context_menu.dart` | Add Share + Copy Link menu items |
| `lib/src/features/library/presentation/album_detail_screen.dart` | Add share `IconButton` to app bar |
| `lib/src/features/library/presentation/artist_detail_screen.dart` | Add share `IconButton` to app bar |
| `lib/src/features/playlists/presentation/playlist_detail_screen.dart` | Add share `IconButton` to app bar |
| `lib/src/features/player/presentation/now_playing_screen.dart` | Add share `IconButton` to player controls |
| `lib/src/routing/app_shell.dart` | Wire `AppLinks` deep link listener |
| `android/app/src/main/AndroidManifest.xml` | Add `navis://` intent-filter |
| `ios/Runner/Info.plist` | Add `CFBundleURLTypes` for `navis` scheme |
| `macos/Runner/Info.plist` | Add `CFBundleURLTypes` for `navis` scheme |
| `linux/packaging/com.navis.app.navis.desktop` | Add `x-scheme-handler/navis` to MimeType |
| `lib/l10n/app_en.arb` | Add share-related localization strings |

### Existing Utilities to Reuse

| Utility | Location | Purpose |
|---------|----------|---------|
| `NavService.goToSearch()` | `lib/src/routing/navigation_service.dart:50` | Pre-fills search and navigates to `/search` |
| `searchQueryProvider` | `lib/src/features/search/presentation/search_controller_provider.dart:22` | Search state notifier |
| `coverArtCacheKey` | `lib/src/common_widgets/cover_art_image.dart:11` | Cache manager key for cover art |
| `kCoverArtStandardSize` | `lib/src/common_widgets/cover_art_image.dart:17` | Standard cover art request size (600) |
| `getCoverArtUrl()` | `lib/src/api/subsonic_api_client.dart` | Builds authenticated cover art URL |
| `_readRoot()` | `lib/src/api/subsonic_api_client.dart:628` | Subsonic API request helper |
| `isDesktopRuntime` | `lib/src/routing/desktop_layout.dart` | Platform detection for menu variants |
| `showAppNotice()` | `lib/src/common_widgets/app_notice.dart:83` | SnackBar-style feedback helper |
| `albumProvider` | Used in `album_context_menu.dart` | Fetches album data by ID |

---

## Verification

1. **Codegen:** `make gen` completes without errors
2. **Analysis:** `flutter analyze && dart run custom_lint` passes
3. **Tests:** `flutter test` passes
4. **Format:** `dart format --set-exit-if-changed .` passes
5. **Full gate:** `make check` passes (includes the critical test gates for database and provider violations)

### Manual Testing

6. **Share flow (song):** Long-press a song → tap Share → verify system share sheet appears with share card image + formatted text containing `navis://` URI
7. **Copy Link flow (song):** Long-press a song → tap Copy Link → paste in text editor → verify well-formed `navis://song?title=...&artist=...` URI
8. **Share flow (album):** Open album → tap share icon in app bar → verify share sheet
9. **Share flow (artist):** Open artist → tap share icon → verify share sheet
10. **Share flow (playlist):** Open playlist → tap share icon → verify share sheet
11. **Share flow (now playing):** While playing → tap share icon → verify current song is shared
12. **Deep link (Android):** Run `adb shell am start -a android.intent.action.VIEW -d "navis://song?title=Test&artist=TestArtist"` → verify app opens and navigates to search with "TestArtist Test"
13. **Deep link (iOS):** Run `xcrun simctl openurl booted "navis://song?title=Test&artist=TestArtist"` → verify same
14. **createShare (supported server):** Share a song on a Navidrome server with sharing enabled → verify public URL is included in share text
15. **createShare (unsupported server):** Share on a server without sharing → verify graceful fallback (no error, URL simply omitted)
16. **Share card quality:** Verify the generated PNG looks correct with cover art, text is readable, Navis logo is present, and handles missing cover art gracefully

---

## Implementation Notes & Edge Cases

### Field Name Mapping (Drift vs API models)
- `SongsTableData` uses `artistName` and `albumName` (not `artist` / `album`)
- `AlbumsTableData` uses `name` and `artistName` (not `title` / `artist`)
- The API models (`Song`, `Album`, `Artist`) use different field names — only `SongsTableData` and `AlbumsTableData` are used in the share actions

### AppNotice API
- There is **no** `AppNoticeScope.of()` method — use the helper function `showAppNotice(context, message: ...)` from `app_notice.dart:83`
- Alternatively, use `AppNoticeScope.maybeOf(context)?.show(message: ...)` for null-safe access

### getCoverArtUrl Named Parameters
- Method signature is `getCoverArtUrl({required String id, int? size})` — both parameters are **named**, not positional

### coverArtCacheManagerProvider is a StreamProvider
- Type: `StreamProvider<CacheManager>` (not a simple `Provider`)
- Access via `.asData?.value` with a fallback to `defaultCoverArtCacheManager`
- Defined in `cover_art_image.dart:145`, fallback at line 139

### Cold-Start Deep Link Timing
- When the app launches from a deep link, auth may not be ready yet
- The `AppShell` widget is only mounted after successful login (the router redirects to `/login` when unauthenticated)
- Therefore, if `AppShell.initState` runs, the user IS authenticated — but `getInitialLink()` is async, so defer with `WidgetsBinding.instance.addPostFrameCallback` to ensure the widget tree is fully built before navigating

### Temp File Cleanup
- Share card PNGs written to `getTemporaryDirectory()` should use a unique filename per share (e.g., timestamp-based) to avoid race conditions if the user shares rapidly
- The OS handles temp directory cleanup, but consider deleting the file after sharing completes

### Unicode / Special Characters in URIs
- `Uri()` constructor automatically percent-encodes query parameter values
- `Uri.queryParameters` automatically decodes them
- Song titles with special characters (accents, CJK, emoji) are handled correctly by Dart's `Uri` class

### Desktop Popup Menu Pattern
- Desktop context menus use `Text(...)` children directly — no `ListTile` wrapper, no leading icon
- Mobile bottom sheet menus use `ListTile` with `leading: Icon(...)` and `title: Text(...)`

### Share Plus Platform Support
- `share_plus` v10.x supports Android, iOS, macOS, Linux, Windows, and web
- On Linux, it uses `xdg-open` or D-Bus — verify it works in the target desktop environments
- On Windows, it uses the native share dialog (Windows 10+)

### No Artist/Playlist Context Menus Exist Yet
- There are no `artist_context_menu.dart` or `playlist_context_menu.dart` files
- Share buttons for artists and playlists go on their respective detail screen app bars only
- If context menus for artists/playlists are added later, share actions should be included
