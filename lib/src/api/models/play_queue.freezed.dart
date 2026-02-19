// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'play_queue.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$PlayQueue {

 String? get current; int? get position; String? get username; int? get changed; List<Song> get entries;
/// Create a copy of PlayQueue
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PlayQueueCopyWith<PlayQueue> get copyWith => _$PlayQueueCopyWithImpl<PlayQueue>(this as PlayQueue, _$identity);

  /// Serializes this PlayQueue to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PlayQueue&&(identical(other.current, current) || other.current == current)&&(identical(other.position, position) || other.position == position)&&(identical(other.username, username) || other.username == username)&&(identical(other.changed, changed) || other.changed == changed)&&const DeepCollectionEquality().equals(other.entries, entries));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,current,position,username,changed,const DeepCollectionEquality().hash(entries));

@override
String toString() {
  return 'PlayQueue(current: $current, position: $position, username: $username, changed: $changed, entries: $entries)';
}


}

/// @nodoc
abstract mixin class $PlayQueueCopyWith<$Res>  {
  factory $PlayQueueCopyWith(PlayQueue value, $Res Function(PlayQueue) _then) = _$PlayQueueCopyWithImpl;
@useResult
$Res call({
 String? current, int? position, String? username, int? changed, List<Song> entries
});




}
/// @nodoc
class _$PlayQueueCopyWithImpl<$Res>
    implements $PlayQueueCopyWith<$Res> {
  _$PlayQueueCopyWithImpl(this._self, this._then);

  final PlayQueue _self;
  final $Res Function(PlayQueue) _then;

/// Create a copy of PlayQueue
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? current = freezed,Object? position = freezed,Object? username = freezed,Object? changed = freezed,Object? entries = null,}) {
  return _then(_self.copyWith(
current: freezed == current ? _self.current : current // ignore: cast_nullable_to_non_nullable
as String?,position: freezed == position ? _self.position : position // ignore: cast_nullable_to_non_nullable
as int?,username: freezed == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String?,changed: freezed == changed ? _self.changed : changed // ignore: cast_nullable_to_non_nullable
as int?,entries: null == entries ? _self.entries : entries // ignore: cast_nullable_to_non_nullable
as List<Song>,
  ));
}

}


/// Adds pattern-matching-related methods to [PlayQueue].
extension PlayQueuePatterns on PlayQueue {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _PlayQueue value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _PlayQueue() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _PlayQueue value)  $default,){
final _that = this;
switch (_that) {
case _PlayQueue():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _PlayQueue value)?  $default,){
final _that = this;
switch (_that) {
case _PlayQueue() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? current,  int? position,  String? username,  int? changed,  List<Song> entries)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _PlayQueue() when $default != null:
return $default(_that.current,_that.position,_that.username,_that.changed,_that.entries);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? current,  int? position,  String? username,  int? changed,  List<Song> entries)  $default,) {final _that = this;
switch (_that) {
case _PlayQueue():
return $default(_that.current,_that.position,_that.username,_that.changed,_that.entries);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? current,  int? position,  String? username,  int? changed,  List<Song> entries)?  $default,) {final _that = this;
switch (_that) {
case _PlayQueue() when $default != null:
return $default(_that.current,_that.position,_that.username,_that.changed,_that.entries);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _PlayQueue implements PlayQueue {
  const _PlayQueue({this.current, this.position, this.username, this.changed, final  List<Song> entries = const <Song>[]}): _entries = entries;
  factory _PlayQueue.fromJson(Map<String, dynamic> json) => _$PlayQueueFromJson(json);

@override final  String? current;
@override final  int? position;
@override final  String? username;
@override final  int? changed;
 final  List<Song> _entries;
@override@JsonKey() List<Song> get entries {
  if (_entries is EqualUnmodifiableListView) return _entries;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_entries);
}


/// Create a copy of PlayQueue
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$PlayQueueCopyWith<_PlayQueue> get copyWith => __$PlayQueueCopyWithImpl<_PlayQueue>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PlayQueueToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _PlayQueue&&(identical(other.current, current) || other.current == current)&&(identical(other.position, position) || other.position == position)&&(identical(other.username, username) || other.username == username)&&(identical(other.changed, changed) || other.changed == changed)&&const DeepCollectionEquality().equals(other._entries, _entries));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,current,position,username,changed,const DeepCollectionEquality().hash(_entries));

@override
String toString() {
  return 'PlayQueue(current: $current, position: $position, username: $username, changed: $changed, entries: $entries)';
}


}

/// @nodoc
abstract mixin class _$PlayQueueCopyWith<$Res> implements $PlayQueueCopyWith<$Res> {
  factory _$PlayQueueCopyWith(_PlayQueue value, $Res Function(_PlayQueue) _then) = __$PlayQueueCopyWithImpl;
@override @useResult
$Res call({
 String? current, int? position, String? username, int? changed, List<Song> entries
});




}
/// @nodoc
class __$PlayQueueCopyWithImpl<$Res>
    implements _$PlayQueueCopyWith<$Res> {
  __$PlayQueueCopyWithImpl(this._self, this._then);

  final _PlayQueue _self;
  final $Res Function(_PlayQueue) _then;

/// Create a copy of PlayQueue
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? current = freezed,Object? position = freezed,Object? username = freezed,Object? changed = freezed,Object? entries = null,}) {
  return _then(_PlayQueue(
current: freezed == current ? _self.current : current // ignore: cast_nullable_to_non_nullable
as String?,position: freezed == position ? _self.position : position // ignore: cast_nullable_to_non_nullable
as int?,username: freezed == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String?,changed: freezed == changed ? _self.changed : changed // ignore: cast_nullable_to_non_nullable
as int?,entries: null == entries ? _self._entries : entries // ignore: cast_nullable_to_non_nullable
as List<Song>,
  ));
}


}

// dart format on
