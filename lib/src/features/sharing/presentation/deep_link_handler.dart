import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/sharing/domain/share_content.dart';
import 'package:navis/src/routing/navigation_service.dart';

/// Handles incoming `navis://` deep links by routing to the appropriate screen.
abstract final class DeepLinkHandler {
  /// Parses [uri] and navigates the app accordingly.
  ///
  /// For song, album, artist, and playlist links the app falls back to a
  /// full-text search because the deep link only carries names/IDs that may
  /// not match an item the current server knows about (the sender and receiver
  /// can be connected to different Subsonic servers).
  static void handleUri(BuildContext context, WidgetRef ref, Uri uri) {
    final content = ShareContent.fromUri(uri);
    if (content == null) return;

    final query = content.searchQuery;
    if (query.isEmpty) return;

    NavService.goToSearch(context, ref, query);
  }
}
