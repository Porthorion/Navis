import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/artist.dart';

part 'indexes.freezed.dart';
part 'indexes.g.dart';

@freezed
abstract class Indexes with _$Indexes {
  const factory Indexes({
    @JsonKey(fromJson: _lastModifiedFromJson, toJson: _lastModifiedToJson)
    DateTime? lastModified,
    @Default(<IndexesIndex>[])
    @JsonKey(name: 'index')
    List<IndexesIndex> indexes,
    @Default(<Artist>[]) List<Artist> shortcut,
    @Default(<Artist>[]) List<Artist> child,
  }) = _Indexes;

  factory Indexes.fromJson(Map<String, dynamic> json) =>
      _$IndexesFromJson(json);
}

@freezed
abstract class IndexesIndex with _$IndexesIndex {
  const factory IndexesIndex({
    String? name,
    @Default(<Artist>[]) @JsonKey(name: 'artist') List<Artist> artists,
  }) = _IndexesIndex;

  factory IndexesIndex.fromJson(Map<String, dynamic> json) =>
      _$IndexesIndexFromJson(json);
}

DateTime? _lastModifiedFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
  }
  if (value is String) {
    final parsedInt = int.tryParse(value);
    if (parsedInt != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        parsedInt,
        isUtc: true,
      ).toLocal();
    }
    return DateTime.tryParse(value)?.toLocal();
  }
  return null;
}

Object? _lastModifiedToJson(DateTime? value) =>
    value?.toUtc().millisecondsSinceEpoch;
