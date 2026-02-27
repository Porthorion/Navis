import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';

Future<void> showCoverArtViewer(
  BuildContext context, {
  required String? coverArtId,
  required String heroTag,
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
        );
      },
    ),
  );
}

class CoverArtViewerScreen extends StatelessWidget {
  const CoverArtViewerScreen({
    required this.coverArtId,
    required this.heroTag,
    super.key,
  });

  final String coverArtId;
  final String heroTag;

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
        child: Stack(
          children: <Widget>[
            LayoutBuilder(
              builder: (context, constraints) {
                final side = math.min(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                return Center(
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 6,
                    child: Hero(
                      tag: heroTag,
                      transitionOnUserGestures: true,
                      child: CoverArtImage(
                        coverArtId: coverArtId,
                        size: 1600,
                        width: side,
                        height: side,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                );
              },
            ),
            closeButton,
          ],
        ),
      ),
    );
  }
}
