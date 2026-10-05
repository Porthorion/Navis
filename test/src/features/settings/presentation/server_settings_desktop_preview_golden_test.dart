import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool continuous}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(body: _ServerSettingsPreview(continuous: continuous)),
      ),
    );
  }

  testWidgets('server settings before uses stacked dashboard cards', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, continuous: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/server_settings_desktop_before.png'),
    );
  });

  testWidgets(
    'server settings after uses a continuous server information workspace',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester, continuous: true);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/server_settings_desktop_after.png'),
      );
    },
  );
}

class _ServerSettingsPreview extends StatelessWidget {
  const new({required this.continuous});

  final bool continuous;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final connection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Current connection', style: text.titleMedium),
        const SizedBox(height: 12),
        const _Detail(label: 'URL', value: 'https://sub.example.com'),
        const _Detail(label: 'Username', value: 'khalifa'),
        const _Detail(label: 'API version', value: '1.16.1'),
        const _Detail(label: 'Auth mode', value: 'Token'),
      ],
    );
    final lastFm = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Last.fm', style: text.titleMedium),
        const SizedBox(height: 12),
        const TextField(
          decoration: InputDecoration(
            labelText: 'API Key',
            prefixIcon: Icon(Icons.key_outlined),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            TextButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Get API Key'),
            ),
            const Spacer(),
            FilledButton.tonal(onPressed: () {}, child: const Text('Save')),
          ],
        ),
      ],
    );

    if (!continuous) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(300, 36, 56, 40),
        children: <Widget>[
          Text('Server Information', style: text.headlineSmall),
          const SizedBox(height: 28),
          const Text('Server'),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: connection,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () {},
            child: const Text('Test connection'),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: () {}, child: const Text('Sign out')),
          const SizedBox(height: 28),
          const Text('External services'),
          const SizedBox(height: 8),
          Card(
            child: Padding(padding: const EdgeInsets.all(16), child: lastFm),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(250, 32, 80, 40),
      children: <Widget>[
        TextButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('Settings'),
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
        ),
        const SizedBox(height: 8),
        Text('Server Information', style: text.headlineSmall),
        const SizedBox(height: 28),
        const Text('Server'),
        const SizedBox(height: 12),
        connection,
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Divider(),
        ),
        Wrap(
          spacing: 12,
          children: <Widget>[
            FilledButton.tonal(
              onPressed: () {},
              child: const Text('Test connection'),
            ),
            FilledButton(onPressed: () {}, child: const Text('Sign out')),
          ],
        ),
        const SizedBox(height: 28),
        const Text('External services'),
        const SizedBox(height: 12),
        lastFm,
      ],
    );
  }
}

class _Detail extends StatelessWidget {
  const new({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text('$label: $value'),
    );
  }
}
