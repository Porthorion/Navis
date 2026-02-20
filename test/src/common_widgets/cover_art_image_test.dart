import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/providers/app_providers.dart';

Widget _buildWidget({
  required Widget child,
  List<Object> overrides = const <Object>[],
}) {
  return ProviderScope(
    overrides: overrides.cast(),
    child: MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('CoverArtImage', () {
    testWidgets('renders fallback icon when coverArtId is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildWidget(
          child: const CoverArtImage(
            coverArtId: null,
            width: 64,
            height: 64,
            placeholderIcon: Icons.album_outlined,
          ),
        ),
      );

      expect(find.byIcon(Icons.album_outlined), findsOneWidget);
    });

    testWidgets('renders fallback icon when api client is unavailable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildWidget(
          overrides: <Object>[
            subsonicApiProvider.overrideWith((_) => null),
          ],
          child: const CoverArtImage(
            coverArtId: 'cover-1',
            width: 64,
            height: 64,
            placeholderIcon: Icons.music_note_outlined,
          ),
        ),
      );

      expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
    });
  });
}
