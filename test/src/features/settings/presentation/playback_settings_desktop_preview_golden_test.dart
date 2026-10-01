import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool bounded}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(body: _PlaybackSettingsPreview(bounded: bounded)),
      ),
    );
  }

  testWidgets('playback settings before has no nested return path', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, bounded: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/playback_settings_desktop_before.png'),
    );
  });

  testWidgets('playback settings after has bounded workspace navigation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, bounded: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/playback_settings_desktop_after.png'),
    );
  });
}

class _PlaybackSettingsPreview extends StatelessWidget {
  const new({required this.bounded});

  final bool bounded;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final settings = <Widget>[
      Text('Wi-Fi Streaming', style: text.titleMedium),
      const SizedBox(height: 12),
      const _Field(label: 'Max bitrate', value: 'Original quality'),
      const SizedBox(height: 12),
      const _Field(label: 'Preferred format', value: 'Server default'),
      const SizedBox(height: 28),
      Text('Cellular streaming', style: text.titleMedium),
      const SizedBox(height: 12),
      const _Field(label: 'Max bitrate', value: '192 kbps'),
      const SizedBox(height: 12),
      const _Field(label: 'Preferred format', value: 'OPUS'),
      const SizedBox(height: 20),
      const SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: true,
        onChanged: null,
        title: Text('Enable scrobbling'),
        subtitle: Text('Report tracks you play to the server.'),
      ),
      const SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: true,
        onChanged: null,
        title: Text('Enable gapless playback'),
        subtitle: Text('Move to the next track without a pause.'),
      ),
    ];

    return ListView(
      padding: bounded
          ? const EdgeInsets.fromLTRB(250, 32, 80, 40)
          : const EdgeInsets.fromLTRB(250, 42, 36, 40),
      children: <Widget>[
        if (bounded) ...<Widget>[
          TextButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Settings'),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
          ),
          const SizedBox(height: 8),
        ],
        Text('Playback', style: text.headlineSmall),
        const SizedBox(height: 32),
        ...settings,
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const new({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: Text(value),
    );
  }
}
