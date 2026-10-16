import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool continuous}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(body: _SyncSettingsPreview(continuous: continuous)),
      ),
    );
  }

  testWidgets('sync settings before uses disconnected dashboard cards', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, continuous: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/sync_settings_desktop_before.png'),
    );
  });

  testWidgets('sync settings after uses a continuous settings workspace', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, continuous: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/sync_settings_desktop_after.png'),
    );
  });
}

class _SyncSettingsPreview extends StatelessWidget {
  const new({required this.continuous});

  final bool continuous;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final Widget summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Current sync status', style: text.titleMedium),
        const SizedBox(height: 8),
        Text('Idle', style: text.bodyLarge),
        const SizedBox(height: 8),
        Text(
          'Last checked Friday, August 14 at 4:27 PM',
          style: text.bodySmall,
        ),
      ],
    );
    final Widget timing = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Schedule', style: text.titleMedium),
        const SizedBox(height: 10),
        _SettingRow(
          title: 'Next automatic check',
          value: 'Saturday, August 15 at 3:40 AM',
        ),
        const Divider(height: 24),
        const _SettingRow(
          title: 'Background sync on unmetered networks',
          value: 'Use Wi-Fi for catalog changes',
          trailing: Switch(value: true, onChanged: null),
        ),
      ],
    );
    if (!continuous) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(280, 36, 48, 36),
        children: <Widget>[
          Text('Sync Settings', style: text.headlineSmall),
          const SizedBox(height: 28),
          Card(
            child: Padding(padding: const EdgeInsets.all(16), child: summary),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(padding: const EdgeInsets.all(16), child: timing),
          ),
          const SizedBox(height: 14),
          const Card(
            child: ListTile(
              title: Text('Sync interval'),
              subtitle: Text('Every hour'),
              trailing: Icon(Icons.expand_more),
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(240, 32, 72, 36),
      children: <Widget>[
        TextButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('Settings'),
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
        ),
        const SizedBox(height: 8),
        Text('Sync Settings', style: text.headlineSmall),
        const SizedBox(height: 28),
        summary,
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Divider(),
        ),
        timing,
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Divider(),
        ),
        _SettingRow(
          title: 'Sync interval',
          value: 'Every hour',
          trailing: Icon(Icons.expand_more, color: c.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.refresh),
            label: const Text('Sync library now'),
          ),
        ),
      ],
    );
  }
}

class _SettingRow extends StatelessWidget {
  const new({required this.title, required this.value, this.trailing});

  final String title;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: text.titleSmall),
              const SizedBox(height: 3),
              Text(value, style: text.bodyMedium),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}
