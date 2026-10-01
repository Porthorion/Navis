import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool destructiveTone}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              _OfflineBanner(destructiveTone: destructiveTone),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('offline status before uses destructive error treatment', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(640, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, destructiveTone: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/offline_status_before.png'),
    );
  });

  testWidgets('offline status after stays calm while retrying automatically', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(640, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, destructiveTone: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/offline_status_after.png'),
    );
  });
}

class _OfflineBanner extends StatelessWidget {
  const new({required this.destructiveTone});

  final bool destructiveTone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = destructiveTone
        ? colors.onErrorContainer
        : colors.onSurfaceVariant;
    return Material(
      color: destructiveTone
          ? colors.errorContainer
          : colors.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(Icons.cloud_off_outlined, color: foreground),
            const SizedBox(width: 10),
            Text(
              'Server unreachable. Retrying every 30s.',
              style: TextStyle(color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}
