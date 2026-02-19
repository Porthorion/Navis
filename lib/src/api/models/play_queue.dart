import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/song.dart';

part 'play_queue.freezed.dart';
part 'play_queue.g.dart';

@freezed
abstract class PlayQueue with _$PlayQueue {
  const factory PlayQueue({
    String? current,
    int? position,
    String? username,
    int? changed,
    @Default(<Song>[]) List<Song> entries,
  }) = _PlayQueue;

  factory PlayQueue.fromJson(Map<String, dynamic> json) =>
      _$PlayQueueFromJson(json);
}
