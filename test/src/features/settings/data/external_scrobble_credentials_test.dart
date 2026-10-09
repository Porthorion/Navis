import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';

class _Storage extends Mock implements FlutterSecureStorage;

void main() {
  test('platform token deletion rethrows failures', () async {
    final storage = _Storage();
    final failure = StateError('delete failed');
    when(() => storage.delete(key: any(named: 'key'))).thenThrow(failure);
    final store = FlutterExternalScrobbleCredentialStore(storage: storage);
    await expectLater(store.clearListenBrainzToken(), throwsA(same(failure)));
  });

  test('platform token deletion uses the existing secure key', () async {
    final storage = _Storage();
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((_) async {});
    await FlutterExternalScrobbleCredentialStore(storage: storage)
        .clearListenBrainzToken();
    verify(
      () => storage.delete(key: 'navis.external_scrobble.listenbrainz.token'),
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
