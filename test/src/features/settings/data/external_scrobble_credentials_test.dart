import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';

void main() {
  test('clone diagnostics credentials remain process-local', () async {
    final store = CloneDiagnosticsExternalScrobbleCredentialStore();

    expect(await store.readListenBrainzToken(), isNull);

    await store.saveListenBrainzToken('fixture-token');
    expect(await store.readListenBrainzToken(), 'fixture-token');

    await store.clearListenBrainzToken();
    expect(await store.readListenBrainzToken(), isNull);
  });
}
