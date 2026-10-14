import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('worker disables automatic registration and uses only sync plugins', () {
    final source = File(
      'android/app/src/main/kotlin/com/navis/app/navis/NavisBackgroundSyncWorker.kt',
    ).readAsStringSync();
    expect(source, contains('FlutterEngine(context, null, false)'));
    expect(RegExp(r'\bFlutterEngine\(').allMatches(source), hasLength(1));
    expect(source, isNot(contains('GeneratedPluginRegistrant.registerWith')));
    expect(
      source,
      contains('backgroundSyncPlugins().forEach { engine.plugins.add(it) }'),
    );
    final allowlist = RegExp(
      r'backgroundSyncPlugins\(\): List<FlutterPlugin> = listOf\(([\s\S]*?)\n\)',
    ).firstMatch(source)!.group(1)!;
    final plugins = RegExp(r'\b(\w+Plugin)\(\)')
        .allMatches(allowlist)
        .map((match) => match.group(1))
        .toSet();
    expect(plugins, {
      'JniPlugin',
      'JniFlutterPlugin',
      'FlutterSecureStoragePlugin',
      'ConnectivityPlugin',
    });
    expect(
      plugins.intersection({
        'AudioServicePlugin',
        'JustAudioPlugin',
        'AudioSessionPlugin',
        'FlutterLocalNotificationsPlugin',
      }),
      isEmpty,
    );
  });
}
