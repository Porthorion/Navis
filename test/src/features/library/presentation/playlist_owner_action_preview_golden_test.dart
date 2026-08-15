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
          appBar: AppBar(title: const Text('Library · Playlists')),
          body: ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('Server Mix'),
            subtitle: const Text('3 songs'),
            trailing: Builder(
              builder: (buttonContext) => IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: () {
                  if (desktopMenu) {
                    final renderBox =
                        buttonContext.findRenderObject()! as RenderBox;
                    showDesktopContextMenu<String>(
                      context: buttonContext,
                      anchor: renderBox.localToGlobal(
                        renderBox.size.center(Offset.zero),
                      ),
                      items: const <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'rename',
                          child: Text('Rename playlist'),
                        ),
                        PopupMenuDivider(),
                        PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('Delete playlist'),
                        ),
                      ],
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
                            leading: Icon(Icons.edit_outlined),
                            title: Text('Rename playlist'),
                          ),
                          ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: Text('Delete playlist'),
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

  testWidgets('playlist owner actions before use the mobile sheet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, desktopMenu: false);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/playlist_owner_actions_before.png'),
    );
  });

  testWidgets('playlist owner actions after use the anchored menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, desktopMenu: true);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/playlist_owner_actions_after.png'),
    );
  });
}
