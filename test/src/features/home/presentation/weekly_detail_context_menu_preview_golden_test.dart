import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pumpPreview(WidgetTester tester, {required bool desktopMenu}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(
          appBar: AppBar(title: const Text('Weekly Exploration')),
          body: ListTile(
            leading: const Text('1'),
            title: const Text('Weekly Song 1'),
            subtitle: const Text('Artist · Album'),
            trailing: Builder(
              builder: (buttonContext) => IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: () {
                  const actions = <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'play-now',
                      child: Text('Play now'),
                    ),
                    PopupMenuItem<String>(
                      value: 'queue',
                      child: Text('Add to Queue'),
                    ),
                    PopupMenuItem<String>(
                      value: 'next',
                      child: Text('Play next'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem<String>(
                      value: 'playlist',
                      child: Text('Add to playlist'),
                    ),
                    PopupMenuItem<String>(
                      value: 'download',
                      child: Text('Download'),
                    ),
                  ];
                  if (desktopMenu) {
                    final renderBox =
                        buttonContext.findRenderObject()! as RenderBox;
                    showDesktopContextMenu<String>(
                      context: buttonContext,
                      anchor: renderBox.localToGlobal(
                        renderBox.size.center(Offset.zero),
                      ),
                      items: actions,
                    );
                    return;
                  }
                  showModalBottomSheet<void>(
                    context: buttonContext,
                    builder: (sheetContext) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const <Widget>[
                          ListTile(
                            leading: Icon(Icons.play_arrow_outlined),
                            title: Text('Play now'),
                          ),
                          ListTile(
                            leading: Icon(Icons.queue_music_outlined),
                            title: Text('Add to Queue'),
                          ),
                          ListTile(
                            leading: Icon(Icons.playlist_add_outlined),
                            title: Text('Play next'),
                          ),
                          Divider(height: 1),
                          ListTile(
                            leading: Icon(Icons.playlist_add),
                            title: Text('Add to playlist'),
                          ),
                          ListTile(
                            leading: Icon(Icons.download_outlined),
                            title: Text('Download'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('weekly desktop context menu before uses the mobile sheet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, desktopMenu: false);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/weekly_desktop_context_menu_before.png'),
    );
  });

  testWidgets('weekly desktop context menu after uses the anchored menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, desktopMenu: true);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/weekly_desktop_context_menu_after.png'),
    );
  });
}
