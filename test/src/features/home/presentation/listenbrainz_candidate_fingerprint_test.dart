import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';

void main() {
  SongsTableData song(String id, {String? mbid, bool provisional = false}) =>
      SongsTableData(
        id: id,
        title: id,
        recordingMbid: mbid,
        isProvisional: provisional,
        isExternal: false,
      );

  test('fingerprint ignores order but tracks the snapshot inputs', () {
    final a = song('a', mbid: 'm1');
    final b = song('b');
    final base = listenBrainzLocalCandidateFingerprint([a, b]);

    expect(listenBrainzLocalCandidateFingerprint([b, a]), base);
    expect(
      listenBrainzLocalCandidateFingerprint([a, song('b', mbid: 'm2')]),
      isNot(base),
    );
    expect(
      listenBrainzLocalCandidateFingerprint([a, song('b', provisional: true)]),
      isNot(base),
    );
    expect(listenBrainzLocalCandidateFingerprint([a]), isNot(base));
  });
}
