import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';

class _Storage extends Mock implements FlutterSecureStorage;
class _CredentialStore extends Mock implements SecureCredentialStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlutterSecureCredentialStore', () {
    late _Storage storage;
    late FlutterSecureCredentialStore store;

    setUp(() async {
      resetSecureStorageQueue();
      storage = _Storage();
      when(() => storage.delete(key: any(named: 'key')))
          .thenAnswer((_) async {});
      store = FlutterSecureCredentialStore(storage: storage);
      await store.clearPassword();
      await store.clearUserInfo();
      clearInteractions(storage);
    });

    tearDown(() async {
      resetSecureStorageQueue();
      await store.clearPassword();
      await store.clearUserInfo();
    });

    test('failed reads throw without deleting saved credentials', () async {
      when(() => storage.read(key: any(named: 'key')))
          .thenThrow(PlatformException(code: 'keystore_busy'));

      await expectLater(
        store.readPassword(),
        throwsA(isA<CredentialReadException>()),
      );
      await expectLater(
        store.readUserInfo(),
        throwsA(isA<CredentialReadException>()),
      );
      verifyNever(() => storage.delete(key: any(named: 'key')));
      verifyNever(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      );

      when(() => storage.read(key: 'navis.auth.active_server.password'))
          .thenAnswer((_) async => 'fixture');
      expect(await store.readPassword(), 'fixture');
    });

    test('successful absent reads return null', () async {
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);
      expect(await store.readPassword(), isNull);
      expect(await store.readUserInfo(), isNull);
    });

    test('failed saves keep the existing desktop session fallback', () async {
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenThrow(PlatformException(code: 'keychain_unavailable'));
      when(() => storage.read(key: any(named: 'key')))
          .thenThrow(PlatformException(code: 'keychain_unavailable'));

      await store.savePassword('fixture');
      await store.saveUserInfo('proxy:fixture');
      expect(await store.readPassword(), 'fixture');
      expect(await store.readUserInfo(), 'proxy:fixture');

      await store.clearPassword();
      await store.clearUserInfo();
      await expectLater(
        store.readPassword(),
        throwsA(isA<CredentialReadException>()),
      );
      await expectLater(
        store.readUserInfo(),
        throwsA(isA<CredentialReadException>()),
      );
    });

    test(
      'password-only session fallback permits absent URL credentials',
      () async {
        when(
          () => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenThrow(PlatformException(code: 'keyring_unavailable'));
        when(() => storage.read(key: any(named: 'key')))
            .thenThrow(PlatformException(code: 'keyring_unavailable'));

        await store.savePassword('fixture');
        expect(await store.readPassword(), 'fixture');
        expect(await store.readUserInfo(), isNull);
        verifyNever(() => storage.delete(key: any(named: 'key')));

        await store.clearPassword();
        await expectLater(
          store.readUserInfo(),
          throwsA(isA<CredentialReadException>()),
        );
      },
    );

    test(
      'indefinitely pending reads surface as unavailable, not missing',
      () async {
        final pendingStore = FlutterSecureCredentialStore(
          storage: storage,
          storageDeadline: const Duration(milliseconds: 50),
        );
        when(() => storage.read(key: any(named: 'key')))
            .thenAnswer((_) => Completer<String?>().future);

        await expectLater(
          pendingStore.readPassword(),
          throwsA(isA<CredentialReadException>()),
        );
        await expectLater(
          pendingStore.readUserInfo(),
          throwsA(isA<CredentialReadException>()),
        );
        verifyNever(() => storage.delete(key: any(named: 'key')));
        verifyNever(
          () => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        );
      },
    );

    test(
      'a deadline does not release the queue while the native call is stuck',
      () async {
        final stuck = Completer<String?>();
        when(() => storage.read(key: 'navis.auth.active_server.password'))
            .thenAnswer((_) => stuck.future);
        when(() => storage.read(key: 'navis.auth.active_server.user_info'))
            .thenAnswer((_) async => 'info');
        final slowStore = FlutterSecureCredentialStore(
          storage: storage,
          storageDeadline: const Duration(milliseconds: 50),
        );

        await expectLater(
          slowStore.readPassword(),
          throwsA(isA<CredentialReadException>()),
        );
        // The caller still gets its deadline, but the next native call must
        // not overlap the stuck one.
        await expectLater(
          slowStore.readUserInfo(),
          throwsA(isA<CredentialReadException>()),
        );
        verifyNever(
          () => storage.read(key: 'navis.auth.active_server.user_info'),
        );

        stuck.complete(null);
        await pumpEventQueue();
        expect(await slowStore.readUserInfo(), 'info');
      },
    );

    group('a delete the keychain refuses', () {
      const passwordKey = 'navis.auth.active_server.password';
      const userInfoKey = 'navis.auth.active_server.user_info';
      late Map<String, String> persisted;

      setUp(() {
        persisted = {passwordKey: 'old-secret', userInfoKey: 'old:proxy'};
        when(() => storage.delete(key: any(named: 'key')))
            .thenThrow(PlatformException(code: '-25244'));
        when(
          () => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((invocation) async {
          persisted[invocation.namedArguments[#key]! as String] =
              invocation.namedArguments[#value]! as String;
        });
        when(() => storage.read(key: any(named: 'key'))).thenAnswer(
          (invocation) async =>
              persisted[invocation.namedArguments[#key]! as String],
        );
      });

      test('is overwritten with an empty value that reads as absent', () async {
        await store.clearPassword();
        await store.clearUserInfo();

        expect(persisted, {passwordKey: '', userInfoKey: ''});
        expect(await store.readPassword(), isNull);
        expect(await store.readUserInfo(), isNull);

        await store.saveUserInfo('new:proxy');
        expect(await store.readUserInfo(), 'new:proxy');
      });

      test('is hidden by a cleared marker when the overwrite fails', () async {
        var failWrites = true;
        when(
          () => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((invocation) async {
          if (failWrites) throw PlatformException(code: '-25244');
          persisted[invocation.namedArguments[#key]! as String] =
              invocation.namedArguments[#value]! as String;
        });

        await store.clearPassword();
        await store.clearUserInfo();

        expect(persisted[userInfoKey], 'old:proxy');
        expect(await store.readPassword(), isNull);
        expect(await store.readUserInfo(), isNull);

        // The marker lasts until a later write succeeds.
        failWrites = false;
        await store.saveUserInfo('new:proxy');
        expect(await store.readUserInfo(), 'new:proxy');
        expect(await store.readPassword(), isNull);
      });
    });

    test('a successful delete stays a plain delete', () async {
      await store.clearPassword();

      verify(() => storage.delete(key: 'navis.auth.active_server.password'))
          .called(1);
      verifyNever(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      );
    });

    test('an empty stored value reads as absent', () async {
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => '');
      expect(await store.readPassword(), isNull);
      expect(await store.readUserInfo(), isNull);
    });

    test('durable stores reject a save that stays memory-only', () async {
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenThrow(PlatformException(code: 'keystore_busy'));
      when(() => storage.read(key: any(named: 'key')))
          .thenThrow(PlatformException(code: 'keystore_busy'));
      final store = FlutterSecureCredentialStore(
        storage: storage,
        requiresDurableCredentials: true,
      );

      await expectLater(
        store.savePassword('fixture'),
        throwsA(isA<CredentialWriteException>()),
      );
      await expectLater(
        store.readPassword(),
        throwsA(isA<CredentialReadException>()),
      );
      verifyNever(() => storage.delete(key: any(named: 'key')));
    });

    test('concurrent native operations never overlap', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      Future<void> track() async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
      }

      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((_) => track());
      when(() => storage.read(key: any(named: 'key'))).thenAnswer((_) async {
        await track();
        return null;
      });

      await Future.wait([
        store.savePassword('fixture-a'),
        store.saveUserInfo('fixture-b'),
        store.readPassword(),
      ]);

      expect(maxInFlight, 1);
    });

    test('failed saves retry and persist once storage recovers', () async {
      final persisted = <String, String>{};
      var writeFailures = 0;
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((invocation) async {
        if (writeFailures < 2) {
          writeFailures++;
          throw PlatformException(code: 'keystore_busy');
        }
        persisted[invocation.namedArguments[#key]! as String] =
            invocation.namedArguments[#value]! as String;
      });
      when(() => storage.read(key: any(named: 'key'))).thenAnswer(
        (invocation) async =>
            persisted[invocation.namedArguments[#key]! as String],
      );

      await store.savePassword('fixture');

      expect(await store.readPassword(), 'fixture');
      verify(
        () => storage.write(
          key: 'navis.auth.active_server.password',
          value: 'fixture',
        ),
      ).called(3);
    });
  });

  test('the macOS service name stays pinned', () {
    expect(
      macOsLoginKeychain.accountName,
      'com.navis.app.navis',
      reason:
          "Renaming the service name orphans every user's stored items "
          'in the login keychain.',
    );
  });

  group('runSerializedSecureStorage', () {
    const deadline = Duration(seconds: 5);

    tearDown(resetSecureStorageQueue);

    test('queue wait does not count against the deadline', () {
      fakeAsync((async) {
        resetSecureStorageQueue();
        final slow = Completer<void>();
        runSerializedSecureStorage(() => slow.future, deadline).ignore();
        String? second;
        runSerializedSecureStorage(() async {
          await Future<void>.delayed(const Duration(seconds: 3));
          return 'done';
        }, deadline).then((value) => second = value);

        async.elapse(const Duration(seconds: 4));
        slow.complete();
        async.flushMicrotasks();
        // Seven seconds after enqueue, but only three after it started.
        async.elapse(const Duration(seconds: 4));
        expect(second, 'done');
      });
    });

    test('a caller waiting behind a stuck call times out unstarted', () {
      fakeAsync((async) {
        resetSecureStorageQueue();
        final stuck = Completer<void>();
        runSerializedSecureStorage(() => stuck.future, deadline).ignore();
        var started = false;
        Object? error;
        runSerializedSecureStorage(
          () async => started = true,
          deadline,
        ).then<void>((_) {}, onError: (Object e) => error = e);

        async.elapse(deadline + const Duration(milliseconds: 1));
        expect(error, isA<TimeoutException>());

        stuck.complete();
        async.flushMicrotasks();
        expect(started, isFalse);
      });
    });
  });

  test('clone diagnostics retries a failed shared backing read', () async {
    final backing = _CredentialStore();
    final firstLoad = Completer<String?>();
    when(backing.readPassword).thenAnswer((_) => firstLoad.future);
    final clone = CloneDiagnosticsCredentialStore(backing);
    final pending = [clone.readPassword(), clone.readPassword()];
    final failures = [
      for (final read in pending)
        expectLater(read, throwsA(isA<CredentialReadException>())),
    ];
    firstLoad.completeError(const CredentialReadException());
    await Future.wait(failures);
    verify(backing.readPassword).called(1);

    when(backing.readPassword).thenAnswer((_) async => 'fixture');
    expect(await clone.readPassword(), 'fixture');
    expect(await clone.readPassword(), 'fixture');
    verify(backing.readPassword).called(1);
    verifyNever(() => backing.savePassword(any()));
    verifyNever(backing.clearPassword);
  });

  test(
    'Android auth reads preserve storage options and disable reset',
    () async {
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
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(code: 'keystore_busy');
      });

      final store = FlutterSecureCredentialStore();
      await expectLater(
        store.readPassword(),
        throwsA(isA<CredentialReadException>()),
      );
      await expectLater(
        store.readUserInfo(),
        throwsA(isA<CredentialReadException>()),
      );

      expect(calls.map((call) => call.method), ['read', 'read']);
      for (final call in calls) {
        expect((call.arguments as Map)['options'], {
          ...AndroidOptions.defaultOptions.toMap(),
          'resetOnError': 'false',
        });
      }
    },
  );
}
