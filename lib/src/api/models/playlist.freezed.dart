// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'playlist.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Playlist {

 String get id; String get name; int? get songCount; int? get duration; String? get owner;@JsonKey(name: 'public') bool? get isPublic; String? get coverArt; String? get comment; List<Song> get entries;
/// Create a copy of Playlist
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlaylistCopyWith<Playlist> get copyWith => _$PlaylistCopyWithImpl<Playlist>(this as Playlist, _$identity);

  /// Serializes this Playlist to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Playlist&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.songCount, songCount) || other.songCount == songCount)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.owner, owner) || other.owner == owner)&&(identical(other.isPublic, isPublic) || other.isPublic == isPublic)&&(identical(other.coverArt, coverArt) || other.coverArt == coverArt)&&(identical(other.comment, comment) || other.comment == comment)&&const DeepCollectionEquality().equals(other.entries, entries));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,songCount,duration,owner,isPublic,coverArt,comment,const DeepCollectionEquality().hash(entries));

@override
String toString() {
  return 'Playlist(id: $id, name: $name, songCount: $songCount, duration: $duration, owner: $owner, isPublic: $isPublic, coverArt: $coverArt, comment: $comment, entries: $entries)';
}


}

/// @nodoc
abstract mixin class $PlaylistCopyWith<$Res>  {
  factory $PlaylistCopyWith(Playlist value, $Res Function(Playlist) _then) = _$PlaylistCopyWithImpl;
@useResult
$Res call({
 String id, String name, int? songCount, int? duration, String? owner,@JsonKey(name: 'public') bool? isPublic, String? coverArt, String? comment, List<Song> entries
});




}
/// @nodoc
class _$PlaylistCopyWithImpl<$Res>
    implements $PlaylistCopyWith<$Res> {
  _$PlaylistCopyWithImpl(this._self, this._then);

  final Playlist _self;
  final $Res Function(Playlist) _then;

/// Create a copy of Playlist
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? songCount = freezed,Object? duration = freezed,Object? owner = freezed,Object? isPublic = freezed,Object? coverArt = freezed,Object? comment = freezed,Object? entries = null,}) {
  return _then(Playlist(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,songCount: freezed == songCount ? _self.songCount : songCount // ignore: cast_nullable_to_non_nullable
as int?,duration: freezed == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as int?,owner: freezed == owner ? _self.owner : owner // ignore: cast_nullable_to_non_nullable
as String?,isPublic: freezed == isPublic ? _self.isPublic : isPublic // ignore: cast_nullable_to_non_nullable
as bool?,coverArt: freezed == coverArt ? _self.coverArt : coverArt // ignore: cast_nullable_to_non_nullable
as String?,comment: freezed == comment ? _self.comment : comment // ignore: cast_nullable_to_non_nullable
as String?,entries: null == entries ? _self.entries : entries // ignore: cast_nullable_to_non_nullable
as List<Song>,
  ));
}

}


/// Adds pattern-matching-related methods to [Playlist].
extension PlaylistPatterns on Playlist {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Playlist value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Playlist() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Playlist value)  $default,){
final _that = this;
switch (_that) {
case _Playlist():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Playlist value)?  $default,){
final _that = this;
switch (_that) {
case _Playlist() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  int? songCount,  int? duration,  String? owner, @JsonKey(name: 'public')  bool? isPublic,  String? coverArt,  String? comment,  List<Song> entries)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Playlist() when $default != null:
return $default(_that.id,_that.name,_that.songCount,_that.duration,_that.owner,_that.isPublic,_that.coverArt,_that.comment,_that.entries);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  int? songCount,  int? duration,  String? owner, @JsonKey(name: 'public')  bool? isPublic,  String? coverArt,  String? comment,  List<Song> entries)  $default,) {final _that = this;
switch (_that) {
case _Playlist():
return $default(_that.id,_that.name,_that.songCount,_that.duration,_that.owner,_that.isPublic,_that.coverArt,_that.comment,_that.entries);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  int? songCount,  int? duration,  String? owner, @JsonKey(name: 'public')  bool? isPublic,  String? coverArt,  String? comment,  List<Song> entries)?  $default,) {final _that = this;
switch (_that) {
case _Playlist() when $default != null:
return $default(_that.id,_that.name,_that.songCount,_that.duration,_that.owner,_that.isPublic,_that.coverArt,_that.comment,_that.entries);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Playlist implements Playlist {
  const _Playlist({required this.id, required this.name, this.songCount, this.duration, this.owner, @JsonKey(name: 'public') this.isPublic, this.coverArt, this.comment,  List<Song> entries = const <Song>[]}): _entries = entries;
  factory _Playlist.fromJson(Map<String, dynamic> json) => _$PlaylistFromJson(json);

@override final  String id;
@override final  String name;
@override final  int? songCount;
@override final  int? duration;
@override final  String? owner;
@override@JsonKey(name: 'public') final  bool? isPublic;
@override final  String? coverArt;
@override final  String? comment;
 final  List<Song> _entries;
@override@JsonKey() List<Song> get entries {
  if (_entries is EqualUnmodifiableListView) return _entries;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_entries);
}


/// Create a copy of Playlist
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PlaylistCopyWith<_Playlist> get copyWith => __$PlaylistCopyWithImpl<_Playlist>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PlaylistToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Playlist&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.songCount, songCount) || other.songCount == songCount)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.owner, owner) || other.owner == owner)&&(identical(other.isPublic, isPublic) || other.isPublic == isPublic)&&(identical(other.coverArt, coverArt) || other.coverArt == coverArt)&&(identical(other.comment, comment) || other.comment == comment)&&const DeepCollectionEquality().equals(other._entries, _entries));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,songCount,duration,owner,isPublic,coverArt,comment,const DeepCollectionEquality().hash(_entries));

@override
String toString() {
  return 'Playlist(id: $id, name: $name, songCount: $songCount, duration: $duration, owner: $owner, isPublic: $isPublic, coverArt: $coverArt, comment: $comment, entries: $entries)';
}


}

/// @nodoc
abstract mixin class _$PlaylistCopyWith<$Res> implements $PlaylistCopyWith<$Res> {
  factory _$PlaylistCopyWith(_Playlist value, $Res Function(_Playlist) _then) = __$PlaylistCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, int? songCount, int? duration, String? owner,@JsonKey(name: 'public') bool? isPublic, String? coverArt, String? comment, List<Song> entries
});




}
/// @nodoc
class __$PlaylistCopyWithImpl<$Res>
    implements _$PlaylistCopyWith<$Res> {
  __$PlaylistCopyWithImpl(this._self, this._then);

  final _Playlist _self;
  final $Res Function(_Playlist) _then;

/// Create a copy of Playlist
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? songCount = freezed,Object? duration = freezed,Object? owner = freezed,Object? isPublic = freezed,Object? coverArt = freezed,Object? comment = freezed,Object? entries = null,}) {
  return _then(_Playlist(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,songCount: freezed == songCount ? _self.songCount : songCount // ignore: cast_nullable_to_non_nullable
as int?,duration: freezed == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as int?,owner: freezed == owner ? _self.owner : owner // ignore: cast_nullable_to_non_nullable
as String?,isPublic: freezed == isPublic ? _self.isPublic : isPublic // ignore: cast_nullable_to_non_nullable
as bool?,coverArt: freezed == coverArt ? _self.coverArt : coverArt // ignore: cast_nullable_to_non_nullable
as String?,comment: freezed == comment ? _self.comment : comment // ignore: cast_nullable_to_non_nullable
as String?,entries: null == entries ? _self._entries : entries // ignore: cast_nullable_to_non_nullable
as List<Song>,
  ));
}


}

// dart format on
