import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/routing/desktop_commands.dart';

const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final values = <String, String>{};
  final calls = <String>[];
  Completer<void>? passwordReadGate;

  setUp(() {
    resetSecureStorageQueue();
    values.clear();
    calls.clear();
    passwordReadGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, (call) async {
          final arguments = call.arguments! as Map<Object?, Object?>;
          final key = arguments['key']! as String;
          calls.add('${call.method} $key');
          if (call.method == 'read' && key.endsWith('.password')) {
            await passwordReadGate?.future;
          }
          return switch (call.method) {
            'write' => values[key] = arguments['value']! as String,
            'read' => values[key],
            'delete' => values.remove(key),
            _ => throw UnsupportedError('Unexpected secure-storage call'),
          };
        });
  });

  tearDown(() {
    resetSecureStorageQueue();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, null);
  });

  test('password survives a store recreation and can be cleared', () async {
    final original = FlutterSecureCredentialStore();
    final restarted = FlutterSecureCredentialStore();

    await original.savePassword('upgrade-safe-password');
    expect(await restarted.readPassword(), 'upgrade-safe-password');

    await restarted.clearPassword();
    expect(await original.readPassword(), isNull);
  });

  test(
    'external scrobble token survives a store recreation and can be cleared',
    () async {
      const original = FlutterExternalScrobbleCredentialStore();
      const restarted = FlutterExternalScrobbleCredentialStore();

      await original.saveListenBrainzToken('upgrade-safe-token');
      expect(await restarted.readListenBrainzToken(), 'upgrade-safe-token');

      await restarted.clearListenBrainzToken();
      expect(await original.readListenBrainzToken(), isNull);
    },
  );

  test('desktop shortcut bindings survive provider recreation', () async {
    final initial = ProviderContainer();
    addTearDown(initial.dispose);
    initial.read(desktopShortcutBindingsProvider);
    await Future<void>.delayed(Duration.zero);
    initial
        .read(desktopShortcutBindingsProvider.notifier)
        .setBinding(
          DesktopCommandAction.openQuickSearch,
          const DesktopShortcutBinding(key: LogicalKeyboardKey.keyP),
        );
    await Future<void>.delayed(Duration.zero);

    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);

    // Start the provider before waiting for asynchronous secure-storage
    // hydration to finish.
    restarted.read(desktopShortcutBindingsProvider);
    await pumpEventQueue();

    final restored = restarted.read(
      desktopShortcutBindingsProvider,
    )[DesktopCommandAction.openQuickSearch];
    expect(restored, isNotNull);
    expect(restored!.key.keyId, LogicalKeyboardKey.keyP.keyId);
    expect(restored.primaryModifier, isTrue);
    expect(restored.alt, isFalse);
    expect(restored.shift, isFalse);
  });

  test(
    'macOS shortcut storage queues behind an earlier credential call',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      passwordReadGate = Completer<void>();
      final pending = FlutterSecureCredentialStore().readPassword();
      await pumpEventQueue();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(desktopShortcutBindingsProvider);
      await pumpEventQueue();
      expect(calls, ['read navis.auth.active_server.password']);

      passwordReadGate!.complete();
      await pending;
      await pumpEventQueue();
      expect(calls.last, 'read navis.desktop.shortcut_bindings.v1');
    },
  );

  test('other platforms call shortcut storage directly', () async {
    passwordReadGate = Completer<void>();
    final pending = FlutterSecureCredentialStore().readPassword();
    await pumpEventQueue();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(desktopShortcutBindingsProvider);
    await pumpEventQueue();
    expect(calls, contains('read navis.desktop.shortcut_bindings.v1'));

    passwordReadGate!.complete();
    await pending;
  });
}
