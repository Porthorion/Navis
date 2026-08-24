// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'search_result3.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SearchResult3 {

 List<Artist> get artists; List<Album> get albums; List<Song> get songs;
/// Create a copy of SearchResult3
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SearchResult3CopyWith<SearchResult3> get copyWith => _$SearchResult3CopyWithImpl<SearchResult3>(this as SearchResult3, _$identity);

  /// Serializes this SearchResult3 to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SearchResult3&&const DeepCollectionEquality().equals(other.artists, artists)&&const DeepCollectionEquality().equals(other.albums, albums)&&const DeepCollectionEquality().equals(other.songs, songs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(artists),const DeepCollectionEquality().hash(albums),const DeepCollectionEquality().hash(songs));

@override
String toString() {
  return 'SearchResult3(artists: $artists, albums: $albums, songs: $songs)';
}


}

/// @nodoc
abstract mixin class $SearchResult3CopyWith<$Res>  {
  factory $SearchResult3CopyWith(SearchResult3 value, $Res Function(SearchResult3) _then) = _$SearchResult3CopyWithImpl;
@useResult
$Res call({
 List<Artist> artists, List<Album> albums, List<Song> songs
});




}
/// @nodoc
class _$SearchResult3CopyWithImpl<$Res>
    implements $SearchResult3CopyWith<$Res> {
  _$SearchResult3CopyWithImpl(this._self, this._then);

  final SearchResult3 _self;
  final $Res Function(SearchResult3) _then;

/// Create a copy of SearchResult3
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? artists = null,Object? albums = null,Object? songs = null,}) {
  return _then(SearchResult3(
artists: null == artists ? _self.artists : artists // ignore: cast_nullable_to_non_nullable
as List<Artist>,albums: null == albums ? _self.albums : albums // ignore: cast_nullable_to_non_nullable
as List<Album>,songs: null == songs ? _self.songs : songs // ignore: cast_nullable_to_non_nullable
as List<Song>,
  ));
}

}


/// Adds pattern-matching-related methods to [SearchResult3].
extension SearchResult3Patterns on SearchResult3 {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SearchResult3 value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SearchResult3() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SearchResult3 value)  $default,){
final _that = this;
switch (_that) {
case _SearchResult3():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SearchResult3 value)?  $default,){
final _that = this;
switch (_that) {
case _SearchResult3() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<Artist> artists,  List<Album> albums,  List<Song> songs)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SearchResult3() when $default != null:
return $default(_that.artists,_that.albums,_that.songs);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<Artist> artists,  List<Album> albums,  List<Song> songs)  $default,) {final _that = this;
switch (_that) {
case _SearchResult3():
return $default(_that.artists,_that.albums,_that.songs);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<Artist> artists,  List<Album> albums,  List<Song> songs)?  $default,) {final _that = this;
switch (_that) {
case _SearchResult3() when $default != null:
return $default(_that.artists,_that.albums,_that.songs);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SearchResult3 implements SearchResult3 {
  const _SearchResult3({ List<Artist> artists = const <Artist>[],  List<Album> albums = const <Album>[],  List<Song> songs = const <Song>[]}): _artists = artists,_albums = albums,_songs = songs;
  factory _SearchResult3.fromJson(Map<String, dynamic> json) => _$SearchResult3FromJson(json);

 final  List<Artist> _artists;
@override@JsonKey() List<Artist> get artists {
  if (_artists is EqualUnmodifiableListView) return _artists;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_artists);
}

 final  List<Album> _albums;
@override@JsonKey() List<Album> get albums {
  if (_albums is EqualUnmodifiableListView) return _albums;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_albums);
}

 final  List<Song> _songs;
@override@JsonKey() List<Song> get songs {
  if (_songs is EqualUnmodifiableListView) return _songs;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_songs);
}


/// Create a copy of SearchResult3
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SearchResult3CopyWith<_SearchResult3> get copyWith => __$SearchResult3CopyWithImpl<_SearchResult3>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SearchResult3ToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SearchResult3&&const DeepCollectionEquality().equals(other._artists, _artists)&&const DeepCollectionEquality().equals(other._albums, _albums)&&const DeepCollectionEquality().equals(other._songs, _songs));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_artists),const DeepCollectionEquality().hash(_albums),const DeepCollectionEquality().hash(_songs));

@override
String toString() {
  return 'SearchResult3(artists: $artists, albums: $albums, songs: $songs)';
}


}

/// @nodoc
abstract mixin class _$SearchResult3CopyWith<$Res> implements $SearchResult3CopyWith<$Res> {
  factory _$SearchResult3CopyWith(_SearchResult3 value, $Res Function(_SearchResult3) _then) = __$SearchResult3CopyWithImpl;
@override @useResult
$Res call({
 List<Artist> artists, List<Album> albums, List<Song> songs
});




}
/// @nodoc
class __$SearchResult3CopyWithImpl<$Res>
    implements _$SearchResult3CopyWith<$Res> {
  __$SearchResult3CopyWithImpl(this._self, this._then);

  final _SearchResult3 _self;
  final $Res Function(_SearchResult3) _then;

/// Create a copy of SearchResult3
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? artists = null,Object? albums = null,Object? songs = null,}) {
  return _then(_SearchResult3(
artists: null == artists ? _self._artists : artists // ignore: cast_nullable_to_non_nullable
as List<Artist>,albums: null == albums ? _self._albums : albums // ignore: cast_nullable_to_non_nullable
as List<Album>,songs: null == songs ? _self._songs : songs // ignore: cast_nullable_to_non_nullable
as List<Song>,
  ));
}


}

// dart format on
