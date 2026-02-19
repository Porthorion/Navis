import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:navis/src/api/models/album.dart';
import 'package:navis/src/api/models/artist.dart';
import 'package:navis/src/api/models/song.dart';

part 'search_result3.freezed.dart';
part 'search_result3.g.dart';

@freezed
abstract class SearchResult3 with _$SearchResult3 {
  const factory SearchResult3({
    @Default(<Artist>[]) List<Artist> artists,
    @Default(<Album>[]) List<Album> albums,
    @Default(<Song>[]) List<Song> songs,
  }) = _SearchResult3;

  factory SearchResult3.fromJson(Map<String, dynamic> json) =>
      _$SearchResult3FromJson(json);
}
