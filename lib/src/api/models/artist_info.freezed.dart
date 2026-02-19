// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'artist_info.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ArtistInfo {

 String? get biography; String? get musicBrainzId; String? get lastFmUrl; String? get smallImageUrl; String? get mediumImageUrl; String? get largeImageUrl; List<Artist> get similarArtists;
/// Create a copy of ArtistInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ArtistInfoCopyWith<ArtistInfo> get copyWith => _$ArtistInfoCopyWithImpl<ArtistInfo>(this as ArtistInfo, _$identity);

  /// Serializes this ArtistInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ArtistInfo&&(identical(other.biography, biography) || other.biography == biography)&&(identical(other.musicBrainzId, musicBrainzId) || other.musicBrainzId == musicBrainzId)&&(identical(other.lastFmUrl, lastFmUrl) || other.lastFmUrl == lastFmUrl)&&(identical(other.smallImageUrl, smallImageUrl) || other.smallImageUrl == smallImageUrl)&&(identical(other.mediumImageUrl, mediumImageUrl) || other.mediumImageUrl == mediumImageUrl)&&(identical(other.largeImageUrl, largeImageUrl) || other.largeImageUrl == largeImageUrl)&&const DeepCollectionEquality().equals(other.similarArtists, similarArtists));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,biography,musicBrainzId,lastFmUrl,smallImageUrl,mediumImageUrl,largeImageUrl,const DeepCollectionEquality().hash(similarArtists));

@override
String toString() {
  return 'ArtistInfo(biography: $biography, musicBrainzId: $musicBrainzId, lastFmUrl: $lastFmUrl, smallImageUrl: $smallImageUrl, mediumImageUrl: $mediumImageUrl, largeImageUrl: $largeImageUrl, similarArtists: $similarArtists)';
}


}

/// @nodoc
abstract mixin class $ArtistInfoCopyWith<$Res>  {
  factory $ArtistInfoCopyWith(ArtistInfo value, $Res Function(ArtistInfo) _then) = _$ArtistInfoCopyWithImpl;
@useResult
$Res call({
 String? biography, String? musicBrainzId, String? lastFmUrl, String? smallImageUrl, String? mediumImageUrl, String? largeImageUrl, List<Artist> similarArtists
});




}
/// @nodoc
class _$ArtistInfoCopyWithImpl<$Res>
    implements $ArtistInfoCopyWith<$Res> {
  _$ArtistInfoCopyWithImpl(this._self, this._then);

  final ArtistInfo _self;
  final $Res Function(ArtistInfo) _then;

/// Create a copy of ArtistInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? biography = freezed,Object? musicBrainzId = freezed,Object? lastFmUrl = freezed,Object? smallImageUrl = freezed,Object? mediumImageUrl = freezed,Object? largeImageUrl = freezed,Object? similarArtists = null,}) {
  return _then(_self.copyWith(
biography: freezed == biography ? _self.biography : biography // ignore: cast_nullable_to_non_nullable
as String?,musicBrainzId: freezed == musicBrainzId ? _self.musicBrainzId : musicBrainzId // ignore: cast_nullable_to_non_nullable
as String?,lastFmUrl: freezed == lastFmUrl ? _self.lastFmUrl : lastFmUrl // ignore: cast_nullable_to_non_nullable
as String?,smallImageUrl: freezed == smallImageUrl ? _self.smallImageUrl : smallImageUrl // ignore: cast_nullable_to_non_nullable
as String?,mediumImageUrl: freezed == mediumImageUrl ? _self.mediumImageUrl : mediumImageUrl // ignore: cast_nullable_to_non_nullable
as String?,largeImageUrl: freezed == largeImageUrl ? _self.largeImageUrl : largeImageUrl // ignore: cast_nullable_to_non_nullable
as String?,similarArtists: null == similarArtists ? _self.similarArtists : similarArtists // ignore: cast_nullable_to_non_nullable
as List<Artist>,
  ));
}

}


/// Adds pattern-matching-related methods to [ArtistInfo].
extension ArtistInfoPatterns on ArtistInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ArtistInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ArtistInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ArtistInfo value)  $default,){
final _that = this;
switch (_that) {
case _ArtistInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ArtistInfo value)?  $default,){
final _that = this;
switch (_that) {
case _ArtistInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? biography,  String? musicBrainzId,  String? lastFmUrl,  String? smallImageUrl,  String? mediumImageUrl,  String? largeImageUrl,  List<Artist> similarArtists)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ArtistInfo() when $default != null:
return $default(_that.biography,_that.musicBrainzId,_that.lastFmUrl,_that.smallImageUrl,_that.mediumImageUrl,_that.largeImageUrl,_that.similarArtists);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? biography,  String? musicBrainzId,  String? lastFmUrl,  String? smallImageUrl,  String? mediumImageUrl,  String? largeImageUrl,  List<Artist> similarArtists)  $default,) {final _that = this;
switch (_that) {
case _ArtistInfo():
return $default(_that.biography,_that.musicBrainzId,_that.lastFmUrl,_that.smallImageUrl,_that.mediumImageUrl,_that.largeImageUrl,_that.similarArtists);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? biography,  String? musicBrainzId,  String? lastFmUrl,  String? smallImageUrl,  String? mediumImageUrl,  String? largeImageUrl,  List<Artist> similarArtists)?  $default,) {final _that = this;
switch (_that) {
case _ArtistInfo() when $default != null:
return $default(_that.biography,_that.musicBrainzId,_that.lastFmUrl,_that.smallImageUrl,_that.mediumImageUrl,_that.largeImageUrl,_that.similarArtists);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ArtistInfo implements ArtistInfo {
  const _ArtistInfo({this.biography, this.musicBrainzId, this.lastFmUrl, this.smallImageUrl, this.mediumImageUrl, this.largeImageUrl, final  List<Artist> similarArtists = const <Artist>[]}): _similarArtists = similarArtists;
  factory _ArtistInfo.fromJson(Map<String, dynamic> json) => _$ArtistInfoFromJson(json);

@override final  String? biography;
@override final  String? musicBrainzId;
@override final  String? lastFmUrl;
@override final  String? smallImageUrl;
@override final  String? mediumImageUrl;
@override final  String? largeImageUrl;
 final  List<Artist> _similarArtists;
@override@JsonKey() List<Artist> get similarArtists {
  if (_similarArtists is EqualUnmodifiableListView) return _similarArtists;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_similarArtists);
}


/// Create a copy of ArtistInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ArtistInfoCopyWith<_ArtistInfo> get copyWith => __$ArtistInfoCopyWithImpl<_ArtistInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ArtistInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ArtistInfo&&(identical(other.biography, biography) || other.biography == biography)&&(identical(other.musicBrainzId, musicBrainzId) || other.musicBrainzId == musicBrainzId)&&(identical(other.lastFmUrl, lastFmUrl) || other.lastFmUrl == lastFmUrl)&&(identical(other.smallImageUrl, smallImageUrl) || other.smallImageUrl == smallImageUrl)&&(identical(other.mediumImageUrl, mediumImageUrl) || other.mediumImageUrl == mediumImageUrl)&&(identical(other.largeImageUrl, largeImageUrl) || other.largeImageUrl == largeImageUrl)&&const DeepCollectionEquality().equals(other._similarArtists, _similarArtists));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,biography,musicBrainzId,lastFmUrl,smallImageUrl,mediumImageUrl,largeImageUrl,const DeepCollectionEquality().hash(_similarArtists));

@override
String toString() {
  return 'ArtistInfo(biography: $biography, musicBrainzId: $musicBrainzId, lastFmUrl: $lastFmUrl, smallImageUrl: $smallImageUrl, mediumImageUrl: $mediumImageUrl, largeImageUrl: $largeImageUrl, similarArtists: $similarArtists)';
}


}

/// @nodoc
abstract mixin class _$ArtistInfoCopyWith<$Res> implements $ArtistInfoCopyWith<$Res> {
  factory _$ArtistInfoCopyWith(_ArtistInfo value, $Res Function(_ArtistInfo) _then) = __$ArtistInfoCopyWithImpl;
@override @useResult
$Res call({
 String? biography, String? musicBrainzId, String? lastFmUrl, String? smallImageUrl, String? mediumImageUrl, String? largeImageUrl, List<Artist> similarArtists
});




}
/// @nodoc
class __$ArtistInfoCopyWithImpl<$Res>
    implements _$ArtistInfoCopyWith<$Res> {
  __$ArtistInfoCopyWithImpl(this._self, this._then);

  final _ArtistInfo _self;
  final $Res Function(_ArtistInfo) _then;

/// Create a copy of ArtistInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? biography = freezed,Object? musicBrainzId = freezed,Object? lastFmUrl = freezed,Object? smallImageUrl = freezed,Object? mediumImageUrl = freezed,Object? largeImageUrl = freezed,Object? similarArtists = null,}) {
  return _then(_ArtistInfo(
biography: freezed == biography ? _self.biography : biography // ignore: cast_nullable_to_non_nullable
as String?,musicBrainzId: freezed == musicBrainzId ? _self.musicBrainzId : musicBrainzId // ignore: cast_nullable_to_non_nullable
as String?,lastFmUrl: freezed == lastFmUrl ? _self.lastFmUrl : lastFmUrl // ignore: cast_nullable_to_non_nullable
as String?,smallImageUrl: freezed == smallImageUrl ? _self.smallImageUrl : smallImageUrl // ignore: cast_nullable_to_non_nullable
as String?,mediumImageUrl: freezed == mediumImageUrl ? _self.mediumImageUrl : mediumImageUrl // ignore: cast_nullable_to_non_nullable
as String?,largeImageUrl: freezed == largeImageUrl ? _self.largeImageUrl : largeImageUrl // ignore: cast_nullable_to_non_nullable
as String?,similarArtists: null == similarArtists ? _self._similarArtists : similarArtists // ignore: cast_nullable_to_non_nullable
as List<Artist>,
  ));
}


}

// dart format on
