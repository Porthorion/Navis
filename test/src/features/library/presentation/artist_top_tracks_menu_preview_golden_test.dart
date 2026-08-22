import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, bool desktop) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  if (desktop) {
                    showDesktopContextMenu<void>(
                      context: context,
                      anchor: const Offset(450, 190),
                      items: const <PopupMenuEntry<void>>[
                        PopupMenuItem<void>(child: Text('Play now')),
                        PopupMenuItem<void>(child: Text('Add to Queue')),
                        PopupMenuItem<void>(child: Text('Play next')),
                        PopupMenuDivider(),
                        PopupMenuItem<void>(child: Text('Like')),
                        PopupMenuItem<void>(child: Text('Open artist')),
                        PopupMenuItem<void>(child: Text('Open album')),
                        PopupMenuItem<void>(child: Text('Add to playlist')),
                        PopupMenuItem<void>(child: Text('Download')),
                      ],
                    );
                  } else {
                    showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => const SafeArea(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              ListTile(title: Text('Play now')),
                              ListTile(title: Text('Add to Queue')),
                              ListTile(title: Text('Play next')),
                              ListTile(title: Text('Like')),
                              ListTile(title: Text('Open artist')),
                              ListTile(title: Text('Open album')),
                              ListTile(title: Text('Add to playlist')),
                              ListTile(title: Text('Download')),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                },
                child: const Text('More'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
  }

  testWidgets('artist top-track More before uses a sheet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, false);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/artist_top_tracks_menu_before.png'),
    );
  });

  testWidgets('artist top-track More after uses a context menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, true);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/artist_top_tracks_menu_after.png'),
    );
  });
}
