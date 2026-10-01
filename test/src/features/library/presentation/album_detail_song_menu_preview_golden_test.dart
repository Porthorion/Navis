import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pumpMenu(WidgetTester tester, {required bool desktop}) async {
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
                      anchor: const Offset(450, 180),
                      items: const <PopupMenuEntry<void>>[
                        PopupMenuItem<void>(child: Text('Play now')),
                        PopupMenuItem<void>(child: Text('Add to Queue')),
                        PopupMenuItem<void>(child: Text('Play next')),
                        PopupMenuDivider(),
                        PopupMenuItem<void>(child: Text('Like')),
                        PopupMenuItem<void>(child: Text('Rate')),
                        PopupMenuItem<void>(child: Text('Open artist')),
                        PopupMenuItem<void>(child: Text('Add to playlist')),
                        PopupMenuItem<void>(child: Text('Download')),
                      ],
                    );
                  } else {
                    showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => SafeArea(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 420),
                          child: const SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                ListTile(title: Text('Play now')),
                                ListTile(title: Text('Add to Queue')),
                                ListTile(title: Text('Play next')),
                                ListTile(title: Text('Like')),
                                ListTile(title: Text('Rate')),
                                ListTile(title: Text('Open artist')),
                                ListTile(title: Text('Add to playlist')),
                                ListTile(title: Text('Download')),
                              ],
                            ),
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

  testWidgets('album track actions before use a desktop bottom sheet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpMenu(tester, desktop: false);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/album_detail_song_menu_before.png'),
    );
  });

  testWidgets('album track actions after use a desktop context menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpMenu(tester, desktop: true);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/album_detail_song_menu_after.png'),
    );
  });
}
