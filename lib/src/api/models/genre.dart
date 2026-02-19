import 'package:freezed_annotation/freezed_annotation.dart';

part 'genre.freezed.dart';
part 'genre.g.dart';

@freezed
abstract class Genre with _$Genre {
  const factory Genre({
    required String name,
    int? songCount,
    int? albumCount,
  }) = _Genre;

  factory Genre.fromJson(Map<String, dynamic> json) => _$GenreFromJson(json);
}
