// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'album_info.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AlbumInfo {

 String? get notes; String? get musicBrainzId; String? get lastFmUrl; String? get smallImageUrl; String? get mediumImageUrl; String? get largeImageUrl;
/// Create a copy of AlbumInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AlbumInfoCopyWith<AlbumInfo> get copyWith => _$AlbumInfoCopyWithImpl<AlbumInfo>(this as AlbumInfo, _$identity);

  /// Serializes this AlbumInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AlbumInfo&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.musicBrainzId, musicBrainzId) || other.musicBrainzId == musicBrainzId)&&(identical(other.lastFmUrl, lastFmUrl) || other.lastFmUrl == lastFmUrl)&&(identical(other.smallImageUrl, smallImageUrl) || other.smallImageUrl == smallImageUrl)&&(identical(other.mediumImageUrl, mediumImageUrl) || other.mediumImageUrl == mediumImageUrl)&&(identical(other.largeImageUrl, largeImageUrl) || other.largeImageUrl == largeImageUrl));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,notes,musicBrainzId,lastFmUrl,smallImageUrl,mediumImageUrl,largeImageUrl);

@override
String toString() {
  return 'AlbumInfo(notes: $notes, musicBrainzId: $musicBrainzId, lastFmUrl: $lastFmUrl, smallImageUrl: $smallImageUrl, mediumImageUrl: $mediumImageUrl, largeImageUrl: $largeImageUrl)';
}


}

/// @nodoc
abstract mixin class $AlbumInfoCopyWith<$Res>  {
  factory $AlbumInfoCopyWith(AlbumInfo value, $Res Function(AlbumInfo) _then) = _$AlbumInfoCopyWithImpl;
@useResult
$Res call({
 String? notes, String? musicBrainzId, String? lastFmUrl, String? smallImageUrl, String? mediumImageUrl, String? largeImageUrl
});




}
/// @nodoc
class _$AlbumInfoCopyWithImpl<$Res>
    implements $AlbumInfoCopyWith<$Res> {
  _$AlbumInfoCopyWithImpl(this._self, this._then);

  final AlbumInfo _self;
  final $Res Function(AlbumInfo) _then;

/// Create a copy of AlbumInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? notes = freezed,Object? musicBrainzId = freezed,Object? lastFmUrl = freezed,Object? smallImageUrl = freezed,Object? mediumImageUrl = freezed,Object? largeImageUrl = freezed,}) {
  return _then(_self.copyWith(
notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,musicBrainzId: freezed == musicBrainzId ? _self.musicBrainzId : musicBrainzId // ignore: cast_nullable_to_non_nullable
as String?,lastFmUrl: freezed == lastFmUrl ? _self.lastFmUrl : lastFmUrl // ignore: cast_nullable_to_non_nullable
as String?,smallImageUrl: freezed == smallImageUrl ? _self.smallImageUrl : smallImageUrl // ignore: cast_nullable_to_non_nullable
as String?,mediumImageUrl: freezed == mediumImageUrl ? _self.mediumImageUrl : mediumImageUrl // ignore: cast_nullable_to_non_nullable
as String?,largeImageUrl: freezed == largeImageUrl ? _self.largeImageUrl : largeImageUrl // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [AlbumInfo].
extension AlbumInfoPatterns on AlbumInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AlbumInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AlbumInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AlbumInfo value)  $default,){
final _that = this;
switch (_that) {
case _AlbumInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AlbumInfo value)?  $default,){
final _that = this;
switch (_that) {
case _AlbumInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? notes,  String? musicBrainzId,  String? lastFmUrl,  String? smallImageUrl,  String? mediumImageUrl,  String? largeImageUrl)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AlbumInfo() when $default != null:
return $default(_that.notes,_that.musicBrainzId,_that.lastFmUrl,_that.smallImageUrl,_that.mediumImageUrl,_that.largeImageUrl);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? notes,  String? musicBrainzId,  String? lastFmUrl,  String? smallImageUrl,  String? mediumImageUrl,  String? largeImageUrl)  $default,) {final _that = this;
switch (_that) {
case _AlbumInfo():
return $default(_that.notes,_that.musicBrainzId,_that.lastFmUrl,_that.smallImageUrl,_that.mediumImageUrl,_that.largeImageUrl);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? notes,  String? musicBrainzId,  String? lastFmUrl,  String? smallImageUrl,  String? mediumImageUrl,  String? largeImageUrl)?  $default,) {final _that = this;
switch (_that) {
case _AlbumInfo() when $default != null:
return $default(_that.notes,_that.musicBrainzId,_that.lastFmUrl,_that.smallImageUrl,_that.mediumImageUrl,_that.largeImageUrl);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AlbumInfo implements AlbumInfo {
  const _AlbumInfo({this.notes, this.musicBrainzId, this.lastFmUrl, this.smallImageUrl, this.mediumImageUrl, this.largeImageUrl});
  factory _AlbumInfo.fromJson(Map<String, dynamic> json) => _$AlbumInfoFromJson(json);

@override final  String? notes;
@override final  String? musicBrainzId;
@override final  String? lastFmUrl;
@override final  String? smallImageUrl;
@override final  String? mediumImageUrl;
@override final  String? largeImageUrl;

/// Create a copy of AlbumInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AlbumInfoCopyWith<_AlbumInfo> get copyWith => __$AlbumInfoCopyWithImpl<_AlbumInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AlbumInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AlbumInfo&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.musicBrainzId, musicBrainzId) || other.musicBrainzId == musicBrainzId)&&(identical(other.lastFmUrl, lastFmUrl) || other.lastFmUrl == lastFmUrl)&&(identical(other.smallImageUrl, smallImageUrl) || other.smallImageUrl == smallImageUrl)&&(identical(other.mediumImageUrl, mediumImageUrl) || other.mediumImageUrl == mediumImageUrl)&&(identical(other.largeImageUrl, largeImageUrl) || other.largeImageUrl == largeImageUrl));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,notes,musicBrainzId,lastFmUrl,smallImageUrl,mediumImageUrl,largeImageUrl);

@override
String toString() {
  return 'AlbumInfo(notes: $notes, musicBrainzId: $musicBrainzId, lastFmUrl: $lastFmUrl, smallImageUrl: $smallImageUrl, mediumImageUrl: $mediumImageUrl, largeImageUrl: $largeImageUrl)';
}


}

/// @nodoc
abstract mixin class _$AlbumInfoCopyWith<$Res> implements $AlbumInfoCopyWith<$Res> {
  factory _$AlbumInfoCopyWith(_AlbumInfo value, $Res Function(_AlbumInfo) _then) = __$AlbumInfoCopyWithImpl;
@override @useResult
$Res call({
 String? notes, String? musicBrainzId, String? lastFmUrl, String? smallImageUrl, String? mediumImageUrl, String? largeImageUrl
});




}
/// @nodoc
class __$AlbumInfoCopyWithImpl<$Res>
    implements _$AlbumInfoCopyWith<$Res> {
  __$AlbumInfoCopyWithImpl(this._self, this._then);

  final _AlbumInfo _self;
  final $Res Function(_AlbumInfo) _then;

/// Create a copy of AlbumInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? notes = freezed,Object? musicBrainzId = freezed,Object? lastFmUrl = freezed,Object? smallImageUrl = freezed,Object? mediumImageUrl = freezed,Object? largeImageUrl = freezed,}) {
  return _then(_AlbumInfo(
notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,musicBrainzId: freezed == musicBrainzId ? _self.musicBrainzId : musicBrainzId // ignore: cast_nullable_to_non_nullable
as String?,lastFmUrl: freezed == lastFmUrl ? _self.lastFmUrl : lastFmUrl // ignore: cast_nullable_to_non_nullable
as String?,smallImageUrl: freezed == smallImageUrl ? _self.smallImageUrl : smallImageUrl // ignore: cast_nullable_to_non_nullable
as String?,mediumImageUrl: freezed == mediumImageUrl ? _self.mediumImageUrl : mediumImageUrl // ignore: cast_nullable_to_non_nullable
as String?,largeImageUrl: freezed == largeImageUrl ? _self.largeImageUrl : largeImageUrl // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
