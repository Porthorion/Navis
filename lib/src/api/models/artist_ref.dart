/// Minimal artist reference embedded inside Album and Song API responses.
///
/// OpenSubsonic extends `AlbumID3` and `Child` with an `artists` list where
/// each entry has at minimum `id` and `name`. We model that as [ArtistRef]
/// rather than reusing the full [Artist] type (which carries albumCount,
/// coverArt, etc.) to keep the JSON mapping lightweight.
///
/// @docImport 'package:navis/src/api/models/artist.dart';
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'artist_ref.freezed.dart';
part 'artist_ref.g.dart';

@freezed
abstract class ArtistRef with _$ArtistRef {
  const factory({required String id, required String name}) = _ArtistRef;

  factory fromJson(Map<String, dynamic> json) => _$ArtistRefFromJson(json);
}
