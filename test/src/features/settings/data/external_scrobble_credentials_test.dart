import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';

class _Storage extends Mock implements FlutterSecureStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSecureStorageQueue);
  tearDown(resetSecureStorageQueue);

  test('Android scrobble reads disable destructive reset only', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });
    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return 'fixture-token';
    });

    expect(
      await const FlutterExternalScrobbleCredentialStore()
          .readListenBrainzToken(),
      'fixture-token',
    );
    expect(captured?.method, 'read');
    expect((captured!.arguments as Map)['options'], {
      ...AndroidOptions.defaultOptions.toMap(),
      'resetOnError': 'false',
    });
  });

  test(
    'secure token deletion propagates failures without changing storage',
    () async {
      final storage = _Storage();
      when(() => storage.delete(key: any(named: 'key')))
          .thenThrow(StateError('fixture storage failure'));
      final store = FlutterExternalScrobbleCredentialStore(storage: storage);
      await expectLater(store.clearListenBrainzToken(), throwsStateError);
      verify(() => storage.delete(key: any(named: 'key'))).called(1);
    },
  );

  test('platform token deletion uses the existing secure key', () async {
    final storage = _Storage();
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((_) async {});
    await FlutterExternalScrobbleCredentialStore(storage: storage)
        .clearListenBrainzToken();
    verify(
      () => storage.delete(key: 'navis.external_scrobble.listenbrainz.token'),
    ).called(1);
  });

  test('pending token reads surface as unavailable, not absent', () async {
    final storage = _Storage();
    when(() => storage.read(key: any(named: 'key')))
        .thenAnswer((_) => Completer<String?>().future);
    final store = FlutterExternalScrobbleCredentialStore(
      storage: storage,
      storageDeadline: const Duration(milliseconds: 50),
    );

    await expectLater(
      store.readListenBrainzToken(),
      throwsA(isA<CredentialReadException>()),
    );
    verifyNever(() => storage.delete(key: any(named: 'key')));
  });

  test('token read failures propagate as unavailable, not null', () async {
    final storage = _Storage();
    when(() => storage.read(key: any(named: 'key')))
        .thenThrow(PlatformException(code: 'keystore_busy'));
    final store = FlutterExternalScrobbleCredentialStore(storage: storage);
    await expectLater(
      store.readListenBrainzToken(),
      throwsA(isA<CredentialReadException>()),
    );
    verifyNever(() => storage.delete(key: any(named: 'key')));
  });

  test('token writes wait for an in-flight auth-store native call', () async {
    final authStorage = _Storage();
    final tokenStorage = _Storage();
    final authRead = Completer<String?>();
    when(() => authStorage.read(key: any(named: 'key')))
        .thenAnswer((_) => authRead.future);
    when(
      () => tokenStorage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
    final auth = FlutterSecureCredentialStore(storage: authStorage);
    final tokens = FlutterExternalScrobbleCredentialStore(
      storage: tokenStorage,
    );

    final pendingRead = auth.readPassword();
    final pendingWrite = tokens.saveListenBrainzToken('fixture-token');
    await pumpEventQueue();
    verifyNever(
      () => tokenStorage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    );

    authRead.complete('fixture');
    await pendingRead;
    await pendingWrite;
    verify(
      () => tokenStorage.write(
        key: 'navis.external_scrobble.listenbrainz.token',
        value: 'fixture-token',
      ),
    ).called(1);
  });

  test('clone diagnostics credentials remain process-local', () async {
    final store = CloneDiagnosticsExternalScrobbleCredentialStore();

    expect(await store.readListenBrainzToken(), isNull);

    await store.saveListenBrainzToken('fixture-token');
    expect(await store.readListenBrainzToken(), 'fixture-token');

    await store.clearListenBrainzToken();
    expect(await store.readListenBrainzToken(), isNull);
  });
}
