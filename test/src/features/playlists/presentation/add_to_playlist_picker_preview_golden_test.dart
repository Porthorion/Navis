import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Widget picker() => Column(
    children: <Widget>[
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: <Widget>[
            Text('Add to playlist'),
            Spacer(),
            Icon(Icons.close),
          ],
        ),
      ),
      const Divider(),
      const ListTile(leading: Icon(Icons.add), title: Text('New playlist')),
      Expanded(
        child: ListView(
          children: const <Widget>[
            ListTile(
              leading: Icon(Icons.queue_music),
              title: Text('Focus mix'),
              subtitle: Text('18 songs'),
            ),
            ListTile(
              leading: Icon(Icons.queue_music),
              title: Text('Road trip'),
              subtitle: Text('42 songs'),
            ),
          ],
        ),
      ),
    ],
  );

  Future<void> pumpPreview(WidgetTester tester, {required bool desktop}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(
          appBar: AppBar(title: const Text('Library')),
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () {
                  if (desktop) {
                    showDialog<void>(
                      context: context,
                      builder: (context) => Dialog(
                        child: SizedBox(
                          width: 460,
                          height: 480,
                          child: picker(),
                        ),
                      ),
                    );
                    return;
                  }
                  showModalBottomSheet<void>(
                    context: context,
                    builder: (context) =>
                        SizedBox(height: 360, child: picker()),
                  );
                },
                child: const Text('Add to playlist'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('picker before uses the desktop bottom sheet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, desktop: false);
    await tester.tap(find.text('Add to playlist'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/add_to_playlist_before.png'),
    );
  });

  testWidgets('picker after uses the desktop dialog', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpPreview(tester, desktop: true);
    await tester.tap(find.text('Add to playlist'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/add_to_playlist_after.png'),
    );
  });
}
