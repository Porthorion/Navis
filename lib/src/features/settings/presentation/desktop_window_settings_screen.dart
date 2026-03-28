import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/routing/desktop_layout.dart';

class DesktopWindowSettingsScreen extends ConsumerWidget {
  const DesktopWindowSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final desktopRuntime = adaptiveContext.desktopRuntime;

    if (!desktopRuntime) {
      return Scaffold(
        appBar: AppBar(title: const Text('Desktop Window')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Desktop window controls are only available in the desktop app.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final content = ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: <Widget>[
        DesktopSectionHeader(
          title: 'Desktop Window',
          subtitle:
              'Tune how Navis behaves as a compact desktop player window.',
        ),
        DesktopPanel(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.construction_outlined),
            title: const Text('Focus Player Mode'),
            subtitle: const Text(
              'This experimental feature is coming in a future update.',
            ),
          ),
        ),
      ],
    );

    if (adaptiveContext.useDesktopShell) {
      return Scaffold(
        appBar: AppBar(title: const Text('Desktop Window')),
        body: DesktopFrame(
          layoutClass: adaptiveContext.desktopLayoutClass,
          child: content,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Desktop Window')),
      body: content,
    );
  }
}
