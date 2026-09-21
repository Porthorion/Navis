// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'album.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Album {

 String get id; String get name; String? get artist; String? get artistId;/// OpenSubsonic extension: multiple album artists with individual IDs.
/// Falls back to the legacy [artist]/[artistId] pair on standard Subsonic.
 List<ArtistRef> get artists; int? get songCount; int? get duration; int? get year; String? get genre; String? get coverArt; DateTime? get starred; int? get userRating; int? get playCount; bool? get isExternal;/// OpenSubsonic extension: MusicBrainz release ID for the album.
/// Absent on standard Subsonic responses.
 String? get musicBrainzId;/// When the album was added to the Subsonic server library.
/// Maps to the `created` field in the Subsonic API response.
 DateTime? get created; List<Song> get songs;
/// Create a copy of Album
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AlbumCopyWith<Album> get copyWith => _$AlbumCopyWithImpl<Album>(this as Album, _$identity);

  /// Serializes this Album to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Album&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.artistId, artistId) || other.artistId == artistId)&&const DeepCollectionEquality().equals(other.artists, artists)&&(identical(other.songCount, songCount) || other.songCount == songCount)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.year, year) || other.year == year)&&(identical(other.genre, genre) || other.genre == genre)&&(identical(other.coverArt, coverArt) || other.coverArt == coverArt)&&(identical(other.starred, starred) || other.starred == starred)&&(identical(other.userRating, userRating) || other.userRating == userRating)&&(identical(other.playCount, playCount) || other.playCount == playCount)&&(identical(other.isExternal, isExternal) || other.isExternal == isExternal)&&(identical(other.musicBrainzId, musicBrainzId) || other.musicBrainzId == musicBrainzId)&&(identical(other.created, created) || other.created == created)&&const DeepCollectionEquality().equals(other.songs, songs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,artist,artistId,const DeepCollectionEquality().hash(artists),songCount,duration,year,genre,coverArt,starred,userRating,playCount,isExternal,musicBrainzId,created,const DeepCollectionEquality().hash(songs));

@override
String toString() {
  return 'Album(id: $id, name: $name, artist: $artist, artistId: $artistId, artists: $artists, songCount: $songCount, duration: $duration, year: $year, genre: $genre, coverArt: $coverArt, starred: $starred, userRating: $userRating, playCount: $playCount, isExternal: $isExternal, musicBrainzId: $musicBrainzId, created: $created, songs: $songs)';
}


}

/// @nodoc
abstract mixin class $AlbumCopyWith<$Res>  {
  factory $AlbumCopyWith(Album value, $Res Function(Album) _then) = _$AlbumCopyWithImpl;
@useResult
$Res call({
 String id, String name, String? artist, String? artistId, List<ArtistRef> artists, int? songCount, int? duration, int? year, String? genre, String? coverArt, DateTime? starred, int? userRating, int? playCount, bool? isExternal, String? musicBrainzId, DateTime? created, List<Song> songs
});




}
/// @nodoc
class _$AlbumCopyWithImpl<$Res>
    implements $AlbumCopyWith<$Res> {
  _$AlbumCopyWithImpl(this._self, this._then);

  final Album _self;
  final $Res Function(Album) _then;

/// Create a copy of Album
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? artist = freezed,Object? artistId = freezed,Object? artists = null,Object? songCount = freezed,Object? duration = freezed,Object? year = freezed,Object? genre = freezed,Object? coverArt = freezed,Object? starred = freezed,Object? userRating = freezed,Object? playCount = freezed,Object? isExternal = freezed,Object? musicBrainzId = freezed,Object? created = freezed,Object? songs = null,}) {
  return _then(Album(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,artist: freezed == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String?,artistId: freezed == artistId ? _self.artistId : artistId // ignore: cast_nullable_to_non_nullable
as String?,artists: null == artists ? _self.artists : artists // ignore: cast_nullable_to_non_nullable
as List<ArtistRef>,songCount: freezed == songCount ? _self.songCount : songCount // ignore: cast_nullable_to_non_nullable
as int?,duration: freezed == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as int?,year: freezed == year ? _self.year : year // ignore: cast_nullable_to_non_nullable
as int?,genre: freezed == genre ? _self.genre : genre // ignore: cast_nullable_to_non_nullable
as String?,coverArt: freezed == coverArt ? _self.coverArt : coverArt // ignore: cast_nullable_to_non_nullable
as String?,starred: freezed == starred ? _self.starred : starred // ignore: cast_nullable_to_non_nullable
as DateTime?,userRating: freezed == userRating ? _self.userRating : userRating // ignore: cast_nullable_to_non_nullable
as int?,playCount: freezed == playCount ? _self.playCount : playCount // ignore: cast_nullable_to_non_nullable
as int?,isExternal: freezed == isExternal ? _self.isExternal : isExternal // ignore: cast_nullable_to_non_nullable
as bool?,musicBrainzId: freezed == musicBrainzId ? _self.musicBrainzId : musicBrainzId // ignore: cast_nullable_to_non_nullable
as String?,created: freezed == created ? _self.created : created // ignore: cast_nullable_to_non_nullable
as DateTime?,songs: null == songs ? _self.songs : songs // ignore: cast_nullable_to_non_nullable
as List<Song>,
  ));
}

}


/// Adds pattern-matching-related methods to [Album].
extension AlbumPatterns on Album {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Album value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Album() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Album value)  $default,){
final _that = this;
switch (_that) {
case _Album():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Album value)?  $default,){
final _that = this;
switch (_that) {
case _Album() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String? artist,  String? artistId,  List<ArtistRef> artists,  int? songCount,  int? duration,  int? year,  String? genre,  String? coverArt,  DateTime? starred,  int? userRating,  int? playCount,  bool? isExternal,  String? musicBrainzId,  DateTime? created,  List<Song> songs)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Album() when $default != null:
return $default(_that.id,_that.name,_that.artist,_that.artistId,_that.artists,_that.songCount,_that.duration,_that.year,_that.genre,_that.coverArt,_that.starred,_that.userRating,_that.playCount,_that.isExternal,_that.musicBrainzId,_that.created,_that.songs);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String? artist,  String? artistId,  List<ArtistRef> artists,  int? songCount,  int? duration,  int? year,  String? genre,  String? coverArt,  DateTime? starred,  int? userRating,  int? playCount,  bool? isExternal,  String? musicBrainzId,  DateTime? created,  List<Song> songs)  $default,) {final _that = this;
switch (_that) {
case _Album():
return $default(_that.id,_that.name,_that.artist,_that.artistId,_that.artists,_that.songCount,_that.duration,_that.year,_that.genre,_that.coverArt,_that.starred,_that.userRating,_that.playCount,_that.isExternal,_that.musicBrainzId,_that.created,_that.songs);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String? artist,  String? artistId,  List<ArtistRef> artists,  int? songCount,  int? duration,  int? year,  String? genre,  String? coverArt,  DateTime? starred,  int? userRating,  int? playCount,  bool? isExternal,  String? musicBrainzId,  DateTime? created,  List<Song> songs)?  $default,) {final _that = this;
switch (_that) {
case _Album() when $default != null:
return $default(_that.id,_that.name,_that.artist,_that.artistId,_that.artists,_that.songCount,_that.duration,_that.year,_that.genre,_that.coverArt,_that.starred,_that.userRating,_that.playCount,_that.isExternal,_that.musicBrainzId,_that.created,_that.songs);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(explicitToJson: true)
class _Album implements Album {
  const _Album({required this.id, required this.name, this.artist, this.artistId,  List<ArtistRef> artists = const <ArtistRef>[], this.songCount, this.duration, this.year, this.genre, this.coverArt, this.starred, this.userRating, this.playCount, this.isExternal, this.musicBrainzId, this.created,  List<Song> songs = const <Song>[]}): _artists = artists,_songs = songs;
  factory _Album.fromJson(Map<String, dynamic> json) => _$AlbumFromJson(json);

@override final  String id;
@override final  String name;
@override final  String? artist;
@override final  String? artistId;
/// OpenSubsonic extension: multiple album artists with individual IDs.
/// Falls back to the legacy [artist]/[artistId] pair on standard Subsonic.
 final  List<ArtistRef> _artists;
/// OpenSubsonic extension: multiple album artists with individual IDs.
/// Falls back to the legacy [artist]/[artistId] pair on standard Subsonic.
@override@JsonKey() List<ArtistRef> get artists {
  if (_artists is EqualUnmodifiableListView) return _artists;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_artists);
}

@override final  int? songCount;
@override final  int? duration;
@override final  int? year;
@override final  String? genre;
@override final  String? coverArt;
@override final  DateTime? starred;
@override final  int? userRating;
@override final  int? playCount;
@override final  bool? isExternal;
/// OpenSubsonic extension: MusicBrainz release ID for the album.
/// Absent on standard Subsonic responses.
@override final  String? musicBrainzId;
/// When the album was added to the Subsonic server library.
/// Maps to the `created` field in the Subsonic API response.
@override final  DateTime? created;
 final  List<Song> _songs;
@override@JsonKey() List<Song> get songs {
  if (_songs is EqualUnmodifiableListView) return _songs;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_songs);
}


/// Create a copy of Album
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AlbumCopyWith<_Album> get copyWith => __$AlbumCopyWithImpl<_Album>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AlbumToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Album&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.artistId, artistId) || other.artistId == artistId)&&const DeepCollectionEquality().equals(other._artists, _artists)&&(identical(other.songCount, songCount) || other.songCount == songCount)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.year, year) || other.year == year)&&(identical(other.genre, genre) || other.genre == genre)&&(identical(other.coverArt, coverArt) || other.coverArt == coverArt)&&(identical(other.starred, starred) || other.starred == starred)&&(identical(other.userRating, userRating) || other.userRating == userRating)&&(identical(other.playCount, playCount) || other.playCount == playCount)&&(identical(other.isExternal, isExternal) || other.isExternal == isExternal)&&(identical(other.musicBrainzId, musicBrainzId) || other.musicBrainzId == musicBrainzId)&&(identical(other.created, created) || other.created == created)&&const DeepCollectionEquality().equals(other._songs, _songs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,artist,artistId,const DeepCollectionEquality().hash(_artists),songCount,duration,year,genre,coverArt,starred,userRating,playCount,isExternal,musicBrainzId,created,const DeepCollectionEquality().hash(_songs));

@override
String toString() {
  return 'Album(id: $id, name: $name, artist: $artist, artistId: $artistId, artists: $artists, songCount: $songCount, duration: $duration, year: $year, genre: $genre, coverArt: $coverArt, starred: $starred, userRating: $userRating, playCount: $playCount, isExternal: $isExternal, musicBrainzId: $musicBrainzId, created: $created, songs: $songs)';
}


}

/// @nodoc
abstract mixin class _$AlbumCopyWith<$Res> implements $AlbumCopyWith<$Res> {
  factory _$AlbumCopyWith(_Album value, $Res Function(_Album) _then) = __$AlbumCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String? artist, String? artistId, List<ArtistRef> artists, int? songCount, int? duration, int? year, String? genre, String? coverArt, DateTime? starred, int? userRating, int? playCount, bool? isExternal, String? musicBrainzId, DateTime? created, List<Song> songs
});




}
/// @nodoc
class __$AlbumCopyWithImpl<$Res>
    implements _$AlbumCopyWith<$Res> {
  __$AlbumCopyWithImpl(this._self, this._then);

  final _Album _self;
  final $Res Function(_Album) _then;

/// Create a copy of Album
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? artist = freezed,Object? artistId = freezed,Object? artists = null,Object? songCount = freezed,Object? duration = freezed,Object? year = freezed,Object? genre = freezed,Object? coverArt = freezed,Object? starred = freezed,Object? userRating = freezed,Object? playCount = freezed,Object? isExternal = freezed,Object? musicBrainzId = freezed,Object? created = freezed,Object? songs = null,}) {
  return _then(_Album(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,artist: freezed == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String?,artistId: freezed == artistId ? _self.artistId : artistId // ignore: cast_nullable_to_non_nullable
as String?,artists: null == artists ? _self._artists : artists // ignore: cast_nullable_to_non_nullable
as List<ArtistRef>,songCount: freezed == songCount ? _self.songCount : songCount // ignore: cast_nullable_to_non_nullable
as int?,duration: freezed == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as int?,year: freezed == year ? _self.year : year // ignore: cast_nullable_to_non_nullable
as int?,genre: freezed == genre ? _self.genre : genre // ignore: cast_nullable_to_non_nullable
as String?,coverArt: freezed == coverArt ? _self.coverArt : coverArt // ignore: cast_nullable_to_non_nullable
as String?,starred: freezed == starred ? _self.starred : starred // ignore: cast_nullable_to_non_nullable
as DateTime?,userRating: freezed == userRating ? _self.userRating : userRating // ignore: cast_nullable_to_non_nullable
as int?,playCount: freezed == playCount ? _self.playCount : playCount // ignore: cast_nullable_to_non_nullable
as int?,isExternal: freezed == isExternal ? _self.isExternal : isExternal // ignore: cast_nullable_to_non_nullable
as bool?,musicBrainzId: freezed == musicBrainzId ? _self.musicBrainzId : musicBrainzId // ignore: cast_nullable_to_non_nullable
as String?,created: freezed == created ? _self.created : created // ignore: cast_nullable_to_non_nullable
as DateTime?,songs: null == songs ? _self._songs : songs // ignore: cast_nullable_to_non_nullable
as List<Song>,
  ));
}


}

// dart format on
