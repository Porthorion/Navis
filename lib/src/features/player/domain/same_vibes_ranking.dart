import 'dart:math' as math;

import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// Shared queue, memory and merge identity: one song across its live, remix,
/// acoustic and junk versions; language editions remain distinct.
String? sameVibesCanonicalSongKey(String artist, String title) {
  final artistKey = normalizeMetadata(artist);
  final titleKey = songVersionTitleKey(title);
  if (artistKey.isEmpty || titleKey.isEmpty) return null;
  return '$artistKey|$titleKey';
}

/// [rankSameVibesPool]'s result: [ordered] is the whole pool best first;
/// [featureIds] are the track ids of the top 24 by unpenalised score, the ones
/// whose `/track/{id}` features the caller fetches for the penalties.
class SameVibesRanking {
  const new(this.ordered, this.featureIds);

  final List<DeezerTrack> ordered;
  final List<int> featureIds;
}

DeezerTrack? _none(int trackId) => null;

const _topCount = 24;

/// Ranks a Deezer pool anchored on the seed: the seed artist's radio, the
/// radios and top tracks of its first six related artists and, on refills, the
/// radios of up to two liked songs. Score = list weight by position, plus a
/// bonus for a related (or seed) artist, minus 0.4 for an outsider, plus 0.3
/// per extra list the song appears in; the top 24 then lose points for bpm,
/// release-year and explicitness distance from the seed track. A port of the
/// prototype's `c_anchor` with the same operation order. A null list was not
/// fetched: it adds nothing and does not shift the later weights.
SameVibesRanking rankSameVibesPool({
  required int seedArtistId,
  required List<int> relatedArtistIds,
  required List<DeezerTrack> seedRadio,
  required List<({List<DeezerTrack>? radio, List<DeezerTrack>? top})>
  relatedLists,
  List<List<DeezerTrack>> likedRadios = const [],
  DeezerTrack? seedFeatures,
  DeezerTrack? Function(int trackId) featuresOf = _none,
}) {
  final rrank = <int, int>{
    for (var i = 0; i < relatedArtistIds.length; i++) relatedArtistIds[i]: i,
    seedArtistId: -1,
  };
  final lists = <(double, List<DeezerTrack>)>[(1, seedRadio)];
  for (var i = 0; i < relatedLists.length; i++) {
    final w = 0.8 / (1 + i / 3);
    if (relatedLists[i].radio case final radio?) lists.add((w, radio));
    if (relatedLists[i].top case final top?) lists.add((w * 0.6, top));
  }
  for (final liked in likedRadios) {
    lists.add((0.5, liked));
  }

  final index = <String, int>{}; // key -> position in first-seen order
  final items = <DeezerTrack>[];
  final counts = <int>[];
  final scores = <double>[];
  for (final (w, list) in lists) {
    for (var p = 0; p < list.length; p++) {
      final t = list[p];
      final key = sameVibesCanonicalSongKey(t.artist.name, t.title);
      if (key == null) continue;
      final i = index.putIfAbsent(key, () {
        items.add(t);
        counts.add(0);
        scores.add(0.0);
        return items.length - 1;
      });
      counts[i]++;
      scores[i] += w * (1 - p / math.max(list.length, 1));
    }
  }
  for (var i = 0; i < items.length; i++) {
    final r = rrank[items[i].artist.id];
    scores[i] += r != null ? 0.6 / (1 + (r + 1) / 5) : -0.4;
    scores[i] += 0.3 * (counts[i] - 1);
  }

  // Score desc, first-seen asc; List.sort is not stable, so compare indices.
  int byScore(int a, int b) {
    final c = scores[b].compareTo(scores[a]);
    return c != 0 ? c : a.compareTo(b);
  }

  final order = List<int>.generate(items.length, (i) => i)..sort(byScore);
  final top = order.take(_topCount).toList();
  final featureIds = [for (final i in top) items[i].id];

  if (seedFeatures != null) {
    final seedBpm = _bpm(seedFeatures);
    final seedYear = _year(seedFeatures);
    final seedExplicit = seedFeatures.explicitLyrics;
    for (final i in top) {
      final f = featuresOf(items[i].id);
      if (f == null) continue;
      final bpm = _bpm(f);
      if (seedBpm != null && bpm != null) {
        final d = math.min(
          (bpm * 0.5 - seedBpm).abs(),
          math.min((bpm - seedBpm).abs(), (bpm * 2 - seedBpm).abs()),
        );
        scores[i] -= 0.5 * math.min(d / 20, 1.0);
      }
      final year = _year(f);
      if (seedYear != null && year != null) {
        scores[i] -= 0.4 * math.min((year - seedYear).abs() / 10, 1.5);
      }
      final explicit = f.explicitLyrics;
      if (seedExplicit != null &&
          explicit != null &&
          seedExplicit != explicit) {
        scores[i] -= 0.1;
      }
    }
    // Stable on the unpenalised order, like the prototype's sort of `top`.
    final pos = {for (var n = 0; n < top.length; n++) top[n]: n};
    top.sort((a, b) {
      final c = scores[b].compareTo(scores[a]);
      return c != 0 ? c : pos[a]!.compareTo(pos[b]!);
    });
  }

  final rest = order.skip(_topCount).toList()..sort(byScore);
  return SameVibesRanking([
    for (final i in [...top, ...rest]) items[i],
  ], featureIds);
}

double? _bpm(DeezerTrack t) => (t.bpm ?? 0) > 0 ? t.bpm : null;

int? _year(DeezerTrack t) {
  final date = t.releaseDate;
  if (date == null || date.length < 4) return null;
  final head = date.substring(0, 4);
  if (head == '0000' || !RegExp(r'^\d{4}$').hasMatch(head)) return null;
  return int.parse(head);
}
