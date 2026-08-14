import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool hasRecovery}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(
          body: _DownloadsSearchEmptyPreview(hasRecovery: hasRecovery),
        ),
      ),
    );
  }

  testWidgets('Downloads search empty before leaves the user at a dead end', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, hasRecovery: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/downloads_search_empty_before.png'),
    );
  });

  testWidgets('Downloads search empty after restores the full list directly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, hasRecovery: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/downloads_search_empty_after.png'),
    );
  });
}

class _DownloadsSearchEmptyPreview extends StatelessWidget {
  const _DownloadsSearchEmptyPreview({required this.hasRecovery});

  final bool hasRecovery;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.all(16),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search downloads',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: EmptyState(
            title: 'No results for "missing"',
            icon: Icons.search_off,
            action: hasRecovery
                ? FilledButton.tonalIcon(
                    onPressed: () {},
                    icon: const Icon(Icons.clear_all_outlined),
                    label: const Text('Show all'),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}
