import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/features/player/domain/same_vibes_ranking.dart';

DeezerTrack t(
  int id,
  String title, {
  int artistId = 1,
  String artist = 'A',
  double? bpm,
  String? date,
  bool? explicit,
}) => DeezerTrack(
  id: id,
  title: title,
  artist: DeezerArtist(id: artistId, name: artist),
  bpm: bpm,
  releaseDate: date,
  explicitLyrics: explicit,
);

typedef Lists = ({List<DeezerTrack>? radio, List<DeezerTrack>? top});

SameVibesRanking rank({
  int seedArtistId = 100,
  List<int> related = const [],
  List<DeezerTrack> seedRadio = const [],
  List<Lists> lists = const [],
  List<List<DeezerTrack>> liked = const [],
  DeezerTrack? seed,
  Map<int, DeezerTrack> features = const {},
}) => rankSameVibesPool(
  seedArtistId: seedArtistId,
  relatedArtistIds: related,
  seedRadio: seedRadio,
  relatedLists: lists,
  likedRadios: liked,
  seedFeatures: seed,
  featuresOf: (id) => features[id],
);

List<int> ids(SameVibesRanking r) => [for (final x in r.ordered) x.id];

void main() {
  group('golden against the Python prototype (rec-v4 c_anchor)', () {
    List<DeezerTrack> tracks(Object? raw) => [
      for (final x in raw! as List)
        DeezerTrack.fromJson(Map<String, dynamic>.from(x as Map)),
    ];

    // key_diffs.md lists pairs where Python's song_key and other keys
    // differ (seed 3: "Brand New Day (My Songs Version)", seed 11:
    // "Bullseye (at Radio City Music Hall)"); the app key
    // (sameVibesCanonicalSongKey) matches Python on every fixture, so no
    // golden carries an exception.
    for (final name in const [
      'seed_3',
      'seed_3_b1',
      'seed_9',
      'seed_11',
      'seed_13',
      'seed_17',
    ]) {
      test('$name matches expectedOrder', () {
        final d = jsonDecode(
          File('test/fixtures/same_vibes_rec_v4/$name.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        final seed = d['seed'] as Map<String, dynamic>;
        final feats = <int, DeezerTrack>{
          for (final e in (d['features'] as Map<String, dynamic>).entries)
            int.parse(e.key): DeezerTrack.fromJson({
              'id': int.parse(e.key),
              'title': '',
              ...Map<String, dynamic>.from(e.value as Map),
            }),
        };
        final r = rankSameVibesPool(
          seedArtistId: seed['seedArtistId'] as int,
          relatedArtistIds: List<int>.from(d['relatedIds'] as List),
          seedRadio: tracks(d['seedRadio']),
          relatedLists: [
            for (final x in d['related'] as List)
              (
                radio: x['radio'] == null ? null : tracks(x['radio']),
                top: x['top'] == null ? null : tracks(x['top']),
              ),
          ],
          likedRadios: [
            for (final l in (d['likedRadios'] as List? ?? const [])) tracks(l),
          ],
          seedFeatures: feats[seed['seedTrackId'] as int? ?? -1],
          featuresOf: (id) => feats[id],
        );
        expect(ids(r), List<int>.from(d['expectedOrder'] as List));
        if (name == 'seed_17') expect(r.ordered, isEmpty);
      });
    }
  });

  group('unit', () {
    // Seed-artist songs (id 100) score 0.6 + position weight; outsiders
    // (id 999) score position weight - 0.4. Fillers pad a list so adjacent
    // positions differ by a small, unambiguous margin.
    DeezerTrack s(int id, String title) => t(id, title, artistId: 100);
    DeezerTrack o(int id, String title) => t(id, title, artistId: 999);
    List<DeezerTrack> padded(List<DeezerTrack> head, [int n = 20]) => [
      ...head,
      for (var i = head.length; i < n; i++) o(1000 + i, 'Filler $i'),
    ];

    test('a missing related list keeps the later weights', () {
      // Lists 0 and 1 are not fetched; list 2 keeps weight 0.8/(1+2/3) =
      // 0.48, so x scores 0.48 - 0.4 and loses to y at 0.5 - 0.4. Had the
      // weights shifted, x would get 0.8 - 0.4 and win.
      final x = o(1, 'X');
      final y = o(2, 'Y');
      final r = rank(
        lists: [
          (radio: null, top: null),
          (radio: null, top: null),
          (radio: [x], top: null),
        ],
        liked: [
          [y],
        ],
      );
      expect(ids(r).take(2), [2, 1]);
    });

    test('seed artist +0.6, outsider -0.4', () {
      // outsider: 1.0 - 0.4 = 0.6; seed artist at position 1 of 2: 0.5 + 0.6.
      final r = rank(seedRadio: [o(2, 'O'), s(1, 'S')]);
      expect(ids(r), [1, 2]);
    });

    test('co-occurrence adds 0.3*(cnt-1)', () {
      // y: 1.0 - 0.4 = 0.6. x: 0.5 + 0.5 - 0.4 + 0.3 = 0.9; without the
      // co-occurrence term it would tie y and lose on first-seen order.
      final r = rank(
        seedRadio: [o(2, 'Y')],
        liked: [
          [o(1, 'X')],
          [o(1, 'X')],
        ],
      );
      expect(ids(r), [1, 2]);
    });

    test('bpm distance counts half and double tempo', () {
      // Seed 100 bpm. b (130, d=30) loses the full 0.5; a (200, x0.5 = 100)
      // and c (50, x2 = 100) lose nothing.
      final seed = t(900, 'seed', bpm: 100);
      final b = s(1, 'B');
      final a = s(2, 'A');
      final c = s(3, 'C');
      final r = rank(
        seedRadio: padded([b, a, c]),
        seed: seed,
        features: {
          1: t(1, 'B', bpm: 130),
          2: t(2, 'A', bpm: 200),
          3: t(3, 'C', bpm: 50),
        },
      );
      expect(ids(r).take(3), [2, 3, 1]);
    });

    test('bpm 0 and year 0000 are absent, not a distance', () {
      final seed = t(900, 'seed', bpm: 100, date: '2000-01-01');
      final b = s(1, 'B');
      final a = s(2, 'A');
      // b is always penalised by bpm (130); a must not be.
      final bFeat = t(1, 'B', bpm: 130, date: '2000-01-01');
      final noBpm = rank(
        seedRadio: padded([b, a]),
        seed: seed,
        features: {
          1: bFeat,
          2: t(2, 'A', bpm: 0, date: '2000-01-01'),
        },
      );
      final noYear = rank(
        seedRadio: padded([b, a]),
        seed: seed,
        features: {
          1: bFeat,
          2: t(2, 'A', bpm: 100, date: '0000-00-00'),
        },
      );
      expect(ids(noBpm).take(2), [2, 1]);
      expect(ids(noYear).take(2), [2, 1]);
    });

    test('year distance is capped at 1.5 decades', () {
      // 40 years away costs 0.4*1.5 = 0.6, not 1.6: b (1.6 - 0.6 = 1.0) still
      // beats the outsider filler pool and a unpenalised stays on top.
      final seed = t(900, 'seed', date: '2020-05-01');
      final b = s(1, 'B');
      final a = s(2, 'A');
      final r = rank(
        seedRadio: padded([b, a]),
        seed: seed,
        features: {
          1: t(1, 'B', date: '1980-01-01'), // 1.6 - 0.6 = 1.0 < a 1.55
          2: t(2, 'A', date: '2020-01-01'),
        },
      );
      expect(ids(r).take(2), [2, 1]);
    });

    test('explicit penalty needs both sides known and different', () {
      final b = s(1, 'B');
      final a = s(2, 'A'); // b 1.6, a 1.55
      final bFeat = t(1, 'B', explicit: true);
      // Test helper, two nullable flags read best positionally.
      // ignore: avoid_positional_boolean_parameters
      List<int> run(bool? seedExplicit, bool? aExplicit) => ids(
        rank(
          seedRadio: padded([b, a]),
          seed: t(900, 'seed', explicit: seedExplicit),
          features: {
            1: bFeat,
            2: t(2, 'A', explicit: aExplicit),
          },
        ),
      ).take(2).toList();
      expect(run(false, null), [2, 1]); // b mismatched: 1.5 < 1.55
      expect(run(null, null), [1, 2]); // seed unknown: no penalty
      expect(run(true, null), [1, 2]); // both true: no penalty
    });

    test('a penalised top-24 track stays above rank 25', () {
      final seed = t(900, 'seed', bpm: 100);
      final pool = [for (var i = 1; i <= 30; i++) s(i, 'T$i')];
      final r = rank(
        seedRadio: pool,
        seed: seed,
        features: {for (var i = 1; i <= 24; i++) i: t(i, 'T$i', bpm: 190)},
      );
      expect(ids(r), [for (var i = 1; i <= 30; i++) i]);
      // Alone, the heavily penalised leader (1.6 - 0.5) falls inside the
      // top 24 but never past it, even where T25's 0.6+0.17 is lower.
      final r2 = rank(
        seedRadio: pool,
        seed: seed,
        features: {1: t(1, 'T1', bpm: 190)},
      );
      expect(ids(r2).indexOf(1), inInclusiveRange(1, 23));
    });

    test('equal scores keep first-seen order', () {
      List<int> run(List<DeezerTrack> first, List<DeezerTrack> second) =>
          ids(rank(liked: [first, second]));
      expect(run([o(3, 'C')], [o(4, 'D')]), [3, 4]);
      expect(run([o(4, 'D')], [o(3, 'C')]), [4, 3]);
    });

    test("the first-seen track's artist decides the related rank", () {
      // 'Same' is first seen by an outsider (id 999); its later copy by
      // related artist 5 must not lift it. other (related) 1.5; Same
      // 0.667 + 0.333 - 0.4 + 0.3 = 0.9. Judged by the later copy it would
      // be 1.0 + 0.5 + 0.3 = 1.8 and win.
      final other = t(3, 'Other', artistId: 5, artist: 'Other');
      final first = t(1, 'Same', artistId: 999, artist: 'Out');
      final second = t(2, 'Same', artistId: 5, artist: 'Out');
      final r = rank(related: [5], seedRadio: [other, first, second]);
      expect(ids(r), [3, 1]);
    });

    test('no seed features, no penalties', () {
      final r = rank(
        seedRadio: padded([s(1, 'B'), s(2, 'A')]),
        features: {1: t(1, 'B', bpm: 300, date: '1950-01-01', explicit: true)},
      );
      expect(ids(r).take(2), [1, 2]);
    });

    test('featureIds are the top 24 by unpenalised score', () {
      final pool = [for (var i = 1; i <= 30; i++) s(i, 'T$i')];
      final r = rank(
        seedRadio: pool,
        seed: t(900, 'seed', bpm: 100),
        features: {1: t(1, 'T1', bpm: 190)},
      );
      expect(r.featureIds, [for (var i = 1; i <= 24; i++) i]);
    });
  });
}
