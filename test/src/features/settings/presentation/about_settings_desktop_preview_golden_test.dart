import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool hasReturnPath}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(body: _AboutPreview(hasReturnPath: hasReturnPath)),
      ),
    );
  }

  testWidgets('About before is a nested page without a return path', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, hasReturnPath: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/about_settings_desktop_before.png'),
    );
  });

  testWidgets('About after restores the Settings return path', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, hasReturnPath: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/about_settings_desktop_after.png'),
    );
  });
}

class _AboutPreview extends StatelessWidget {
  const new({required this.hasReturnPath});

  final bool hasReturnPath;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(250, 32, 80, 40),
      children: <Widget>[
        if (hasReturnPath) ...<Widget>[
          TextButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Settings'),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
          ),
          const SizedBox(height: 8),
        ],
        Text('About', style: text.headlineSmall),
        const SizedBox(height: 24),
        const Center(child: Icon(Icons.waves_outlined, size: 96)),
        const SizedBox(height: 12),
        Text('Navis', textAlign: TextAlign.center, style: text.headlineMedium),
        const SizedBox(height: 4),
        Text(
          'Version 1.2.5',
          textAlign: TextAlign.center,
          style: text.bodyMedium,
        ),
        const SizedBox(height: 24),
        Text('Data Usage', style: text.titleSmall),
        const SizedBox(height: 8),
        const _UsageRow(label: 'Today', value: '56.6 MB'),
        const _UsageRow(label: 'Last 7 Days', value: '3.65 GB'),
        const _UsageRow(label: 'Last 30 Days', value: '5.79 GB'),
        const Divider(height: 36),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.description_outlined),
          title: Text('Open-source licenses'),
          subtitle: Text('View third-party software licenses.'),
          trailing: Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

class _UsageRow extends StatelessWidget {
  const new({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: <Widget>[Text(label), const Spacer(), Text(value)]),
    );
  }
}
