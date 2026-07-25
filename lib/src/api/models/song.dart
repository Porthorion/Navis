import 'package:freezed_annotation/freezed_annotation.dart';

part 'song.freezed.dart';
part 'song.g.dart';

@freezed
abstract class Song with _$Song {
  @JsonSerializable(explicitToJson: true)
  const factory Song({
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
    ReplayGain? replayGain,
  }) = _Song;

  factory Song.fromJson(Map<String, dynamic> json) => _$SongFromJson(json);
}

Object? _readSampleRateJson(Map<dynamic, dynamic> json, String _) {
  return json['samplingRate'] ?? json['sampleRate'];
}

/// ReplayGain metadata from the OpenSubsonic API.
@freezed
abstract class ReplayGain with _$ReplayGain {
  const factory ReplayGain({
    double? trackGain,
    double? albumGain,
    double? trackPeak,
    double? albumPeak,
  }) = _ReplayGain;

  factory ReplayGain.fromJson(Map<String, dynamic> json) =>
      _$ReplayGainFromJson(json);
}
