import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/sharing/data/share_card_renderer.dart';
import 'package:navis/src/features/sharing/domain/share_content.dart';
import 'package:navis/src/features/sharing/presentation/share_desktop_dialog.dart';

class ShareService {
  ShareService({
    required this.apiClient,
    required this.cacheManager,
  });

  final SubsonicApiClient? apiClient;
  final BaseCacheManager cacheManager;

  /// Share content via the system share sheet (image + text).
  ///
  /// On Linux and Windows the system share sheet does not support file
  /// sharing, so a custom in-app dialog is shown instead — the caller must
  /// supply a [context] so that dialog can be displayed.
  Future<void> share(
    ShareContent content, {
    String? entityId,
    BuildContext? context,
  }) async {
    final cardBytes = await _generateCard(content);
    final publicUrl = await _tryCreateShare(entityId);
    final text = content.toShareText(publicUrl: publicUrl);

    if (Platform.isLinux || Platform.isWindows) {
      // Desktop platforms don't support native file share sheets.
      if (context != null && context.mounted) {
        await ShareDesktopDialog.show(
          context,
          cardBytes: cardBytes,
          shareText: text,
        );
      }
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${tempDir.path}/navis_share_$timestamp.png');
    await file.writeAsBytes(cardBytes);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: text,
      ),
    );

    // Clean up after sharing.
    try {
      await file.delete();
    } catch (_) {}
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
    final client = apiClient;
    if (client == null) return null;
    try {
      final url = client.getCoverArtUrl(
        id: coverArtId,
        size: kCoverArtStandardSize,
      );
      final fileInfo = await cacheManager.getFileFromCache(url.toString());
      if (fileInfo != null) {
        return fileInfo.file.readAsBytes();
      }
      final file = await cacheManager.getSingleFile(url.toString());
      return file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _tryCreateShare(String? entityId) async {
    if (entityId == null) return null;
    final client = apiClient;
    if (client == null) return null;
    try {
      final shareInfo = await client.createShare(entityId);
      return shareInfo?.url;
    } catch (_) {
      return null;
    }
  }
}
