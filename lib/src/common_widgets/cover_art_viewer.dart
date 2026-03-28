import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';

/// Opens a fullscreen viewer for a plain remote image URL.
/// Used for radio now-playing art that is not a Subsonic cover art ID.
Future<void> showRemoteArtViewer(
  BuildContext context, {
  required String? artUrl,
}) {
  final url = artUrl?.trim() ?? '';
  if (url.isEmpty) {
    return Future<void>.value();
  }

  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 170),
      reverseTransitionDuration: const Duration(milliseconds: 130),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return _RemoteArtViewerScreen(artUrl: url);
      },
    ),
  );
}

class _RemoteArtViewerScreen extends StatelessWidget {
  const _RemoteArtViewerScreen({required this.artUrl});

  final String artUrl;

  @override
  Widget build(BuildContext context) {
    final closeButton = Positioned(
      top: 12,
      right: 12,
      child: SafeArea(
        child: Material(
          color: Colors.black.withValues(alpha: 0.45),
          shape: const CircleBorder(),
          child: IconButton(
            icon: const Icon(Icons.close),
            color: Colors.white,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = math.min(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            final imageLeft = (constraints.maxWidth - side) / 2;
            final imageTop = (constraints.maxHeight - side) / 2;

            return Stack(
              children: <Widget>[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(),
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0).abs() > 300) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: const SizedBox.expand(),
                ),
                Positioned(
                  left: imageLeft,
                  top: imageTop,
                  width: side,
                  height: side,
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 6,
                    child: CachedNetworkImage(
                      imageUrl: artUrl,
                      width: side,
                      height: side,
                      fit: BoxFit.contain,
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                closeButton,
              ],
            );
          },
        ),
      ),
    );
  }
}

Future<void> showCoverArtViewer(
  BuildContext context, {
  required String? coverArtId,
  required String heroTag,
  int previewSize = 320,
}) {
  final id = coverArtId?.trim() ?? '';
  if (id.isEmpty) {
    return Future<void>.value();
  }

  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 170),
      reverseTransitionDuration: const Duration(milliseconds: 130),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return CoverArtViewerScreen(
          coverArtId: id,
          heroTag: heroTag,
          previewSize: previewSize,
        );
      },
    ),
  );
}

class CoverArtViewerScreen extends StatelessWidget {
  const CoverArtViewerScreen({
    required this.coverArtId,
    required this.heroTag,
    required this.previewSize,
    super.key,
  });

  final String coverArtId;
  final String heroTag;
  final int previewSize;

  @override
  Widget build(BuildContext context) {
    final closeButton = Positioned(
      top: 12,
      right: 12,
      child: SafeArea(
        child: Material(
          color: Colors.black.withValues(alpha: 0.45),
          shape: const CircleBorder(),
          child: IconButton(
            icon: const Icon(Icons.close),
            color: Colors.white,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = math.min(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            final imageLeft = (constraints.maxWidth - side) / 2;
            final imageTop = (constraints.maxHeight - side) / 2;

            return Stack(
              children: <Widget>[
                // Full-screen background: tap OR vertical swipe to dismiss.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(),
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0).abs() > 300) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: const SizedBox.expand(),
                ),
                // Image: positioned over the center square only.
                Positioned(
                  left: imageLeft,
                  top: imageTop,
                  width: side,
                  height: side,
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 6,
                    child: Hero(
                      tag: heroTag,
                      transitionOnUserGestures: true,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          CoverArtImage(
                            coverArtId: coverArtId,
                            size: previewSize,
                            width: side,
                            height: side,
                            fit: BoxFit.contain,
                            fadeInDuration: Duration.zero,
                          ),
                          CoverArtImage(
                            coverArtId: coverArtId,
                            size: 1600,
                            width: side,
                            height: side,
                            fit: BoxFit.contain,
                            showLoadingPlaceholder: false,
                            showErrorPlaceholder: false,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                closeButton,
              ],
            );
          },
        ),
      ),
    );
  }
}
