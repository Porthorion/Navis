import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/utils/genre_key.dart';

part 'song.freezed.dart';
part 'song.g.dart';

@freezed
abstract class Song with _$Song {
  @JsonSerializable(explicitToJson: true)
  const factory({
    required String id,
    required String title,
    String? album,
    String? albumId,
    String? artist,
    String? artistId,
    int? track,
    int? discNumber,
    int? year,
    int? duration,
    int? bitRate,
    @JsonKey(readValue: _readSampleRateJson) int? sampleRate,
    String? contentType,
    String? suffix,
    int? size,
    String? coverArt,
    DateTime? starred,
    String? musicBrainzId,
    int? userRating,
    int? playCount,
    DateTime? created,
    bool? isExternal,
    ReplayGain? replayGain,

    /// The song's genres, resolved from the OpenSubsonic `genres` list or,
    /// when that is missing or empty, the legacy `genre` string as one tag.
    /// Never split client-side; blank names and duplicates by merge key are
    /// dropped.
    @JsonKey(readValue: _readGenresJson)
    @Default(<String>[])
    List<String> genres,
  }) = _Song;

  factory fromJson(Map<String, dynamic> json) => _$SongFromJson(json);
}

Object? _readSampleRateJson(Map<dynamic, dynamic> json, String _) {
  return json['samplingRate'] ?? json['sampleRate'];
}

Object? _readGenresJson(Map<dynamic, dynamic> json, String _) {
  final list = json['genres'];
  // Accepts the server's `{name}` objects and plain strings, so a song
  // serialized by [Song.toJson] reads back unchanged.
  final names = list is List
      ? resolveGenres(list.map((e) => (e is Map ? e['name'] : e)?.toString()))
      : const <String>[];
  if (names.isNotEmpty) return names;
  final legacy = json['genre'];
  return legacy is String ? resolveGenres([legacy]) : const <String>[];
}

/// ReplayGain metadata from the OpenSubsonic API.
@freezed
abstract class ReplayGain with _$ReplayGain {
  const factory({
    double? trackGain,
    double? albumGain,
    double? trackPeak,
    double? albumPeak,
  }) = _ReplayGain;

  factory fromJson(Map<String, dynamic> json) => _$ReplayGainFromJson(json);
}
