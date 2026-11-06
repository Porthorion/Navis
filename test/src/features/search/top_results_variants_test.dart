// Phase 1 of item A: prints (and, with TOP_RESULTS_REPORT_DIR set, writes) the
// Top Results picks of the shipped rule and the candidate rules for saved real
// answers. See top_results_variants.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';

import 'top_results_variants.dart';

void main() {
  final fixtures = loadFixtures();

  test('the candidate list matches the shipped matcher', () {
    expect(fixtures, isNotEmpty);
    for (final f in fixtures) {
      final c = Ctx(f);
      final shipped = matchDeezerSearchHits(
        result: f.merged,
        hits: f.hits,
      ).topResults;
      expect(
        [for (final x in c.cands.take(kMaxTopResults)) idOf(x.item)],
        [for (final x in shipped) idOf(x)],
        reason: f.name,
      );
    }
  });

  test('prints every rule for every query', () {
    final out = StringBuffer();
    final rows = <Map<String, Object?>>[];
    for (final f in fixtures) {
      final c = Ctx(f);
      out.writeln(
        '== ${f.query}  (exact kinds: ${c.exactKinds}, '
        'Deezer #1 song: ${c.topTrack?.title} — ${c.topTrack?.artist.name})',
      );
      for (final entry in variants.entries) {
        final picks = entry.value(c);
        out.writeln(
          '  ${entry.key.padRight(8)} ${picks.map((x) => describe(x, f.merged)).join('  |  ')}',
        );
        rows.add({
          'query': f.query,
          'variant': entry.key,
          'picks': [
            for (var i = 0; i < kMaxTopResults; i++)
              describe(i < picks.length ? picks[i] : null, f.merged),
          ],
          'exactKinds': c.exactKinds.length,
          'topSong': '${c.topTrack?.title} — ${c.topTrack?.artist.name}',
        });
      }
    }
    // The report is the output.
    // ignore: avoid_print
    print(out);
    final dir = Platform.environment['TOP_RESULTS_REPORT_DIR'];
    if (dir != null) {
      Directory(dir).createSync(recursive: true);
      File('$dir/variants.txt').writeAsStringSync(out.toString());
      File('$dir/rows.json').writeAsStringSync(jsonEncode(rows));
    }
  });
}
