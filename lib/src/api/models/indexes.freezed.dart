// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'indexes.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Indexes {

@JsonKey(fromJson: _lastModifiedFromJson, toJson: _lastModifiedToJson) DateTime? get lastModified;@JsonKey(name: 'index') List<IndexesIndex> get indexes; List<Artist> get shortcut; List<Artist> get child;
/// Create a copy of Indexes
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IndexesCopyWith<Indexes> get copyWith => _$IndexesCopyWithImpl<Indexes>(this as Indexes, _$identity);

  /// Serializes this Indexes to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Indexes&&(identical(other.lastModified, lastModified) || other.lastModified == lastModified)&&const DeepCollectionEquality().equals(other.indexes, indexes)&&const DeepCollectionEquality().equals(other.shortcut, shortcut)&&const DeepCollectionEquality().equals(other.child, child));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,lastModified,const DeepCollectionEquality().hash(indexes),const DeepCollectionEquality().hash(shortcut),const DeepCollectionEquality().hash(child));

@override
String toString() {
  return 'Indexes(lastModified: $lastModified, indexes: $indexes, shortcut: $shortcut, child: $child)';
}


}

/// @nodoc
abstract mixin class $IndexesCopyWith<$Res>  {
  factory $IndexesCopyWith(Indexes value, $Res Function(Indexes) _then) = _$IndexesCopyWithImpl;
@useResult
$Res call({
@JsonKey(fromJson: _lastModifiedFromJson, toJson: _lastModifiedToJson) DateTime? lastModified,@JsonKey(name: 'index') List<IndexesIndex> indexes, List<Artist> shortcut, List<Artist> child
});




}
/// @nodoc
class _$IndexesCopyWithImpl<$Res>
    implements $IndexesCopyWith<$Res> {
  _$IndexesCopyWithImpl(this._self, this._then);

  final Indexes _self;
  final $Res Function(Indexes) _then;

/// Create a copy of Indexes
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? lastModified = freezed,Object? indexes = null,Object? shortcut = null,Object? child = null,}) {
  return _then(_self.copyWith(
lastModified: freezed == lastModified ? _self.lastModified : lastModified // ignore: cast_nullable_to_non_nullable
as DateTime?,indexes: null == indexes ? _self.indexes : indexes // ignore: cast_nullable_to_non_nullable
as List<IndexesIndex>,shortcut: null == shortcut ? _self.shortcut : shortcut // ignore: cast_nullable_to_non_nullable
as List<Artist>,child: null == child ? _self.child : child // ignore: cast_nullable_to_non_nullable
as List<Artist>,
  ));
}

}


/// Adds pattern-matching-related methods to [Indexes].
extension IndexesPatterns on Indexes {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Indexes value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Indexes() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Indexes value)  $default,){
final _that = this;
switch (_that) {
case _Indexes():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Indexes value)?  $default,){
final _that = this;
switch (_that) {
case _Indexes() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function(@JsonKey(fromJson: _lastModifiedFromJson, toJson: _lastModifiedToJson)  DateTime? lastModified, @JsonKey(name: 'index')  List<IndexesIndex> indexes,  List<Artist> shortcut,  List<Artist> child)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Indexes() when $default != null:
return $default(_that.lastModified,_that.indexes,_that.shortcut,_that.child);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function(@JsonKey(fromJson: _lastModifiedFromJson, toJson: _lastModifiedToJson)  DateTime? lastModified, @JsonKey(name: 'index')  List<IndexesIndex> indexes,  List<Artist> shortcut,  List<Artist> child)  $default,) {final _that = this;
switch (_that) {
case _Indexes():
return $default(_that.lastModified,_that.indexes,_that.shortcut,_that.child);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function(@JsonKey(fromJson: _lastModifiedFromJson, toJson: _lastModifiedToJson)  DateTime? lastModified, @JsonKey(name: 'index')  List<IndexesIndex> indexes,  List<Artist> shortcut,  List<Artist> child)?  $default,) {final _that = this;
switch (_that) {
case _Indexes() when $default != null:
return $default(_that.lastModified,_that.indexes,_that.shortcut,_that.child);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Indexes implements Indexes {
  const _Indexes({@JsonKey(fromJson: _lastModifiedFromJson, toJson: _lastModifiedToJson) this.lastModified, @JsonKey(name: 'index') final  List<IndexesIndex> indexes = const <IndexesIndex>[], final  List<Artist> shortcut = const <Artist>[], final  List<Artist> child = const <Artist>[]}): _indexes = indexes,_shortcut = shortcut,_child = child;
  factory _Indexes.fromJson(Map<String, dynamic> json) => _$IndexesFromJson(json);

@override@JsonKey(fromJson: _lastModifiedFromJson, toJson: _lastModifiedToJson) final  DateTime? lastModified;
 final  List<IndexesIndex> _indexes;
@override@JsonKey(name: 'index') List<IndexesIndex> get indexes {
  if (_indexes is EqualUnmodifiableListView) return _indexes;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_indexes);
}

 final  List<Artist> _shortcut;
@override@JsonKey() List<Artist> get shortcut {
  if (_shortcut is EqualUnmodifiableListView) return _shortcut;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_shortcut);
}

 final  List<Artist> _child;
@override@JsonKey() List<Artist> get child {
  if (_child is EqualUnmodifiableListView) return _child;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_child);
}


/// Create a copy of Indexes
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$IndexesCopyWith<_Indexes> get copyWith => __$IndexesCopyWithImpl<_Indexes>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$IndexesToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Indexes&&(identical(other.lastModified, lastModified) || other.lastModified == lastModified)&&const DeepCollectionEquality().equals(other._indexes, _indexes)&&const DeepCollectionEquality().equals(other._shortcut, _shortcut)&&const DeepCollectionEquality().equals(other._child, _child));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,lastModified,const DeepCollectionEquality().hash(_indexes),const DeepCollectionEquality().hash(_shortcut),const DeepCollectionEquality().hash(_child));

@override
String toString() {
  return 'Indexes(lastModified: $lastModified, indexes: $indexes, shortcut: $shortcut, child: $child)';
}


}

/// @nodoc
abstract mixin class _$IndexesCopyWith<$Res> implements $IndexesCopyWith<$Res> {
  factory _$IndexesCopyWith(_Indexes value, $Res Function(_Indexes) _then) = __$IndexesCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(fromJson: _lastModifiedFromJson, toJson: _lastModifiedToJson) DateTime? lastModified,@JsonKey(name: 'index') List<IndexesIndex> indexes, List<Artist> shortcut, List<Artist> child
});




}
/// @nodoc
class __$IndexesCopyWithImpl<$Res>
    implements _$IndexesCopyWith<$Res> {
  __$IndexesCopyWithImpl(this._self, this._then);

  final _Indexes _self;
  final $Res Function(_Indexes) _then;

/// Create a copy of Indexes
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? lastModified = freezed,Object? indexes = null,Object? shortcut = null,Object? child = null,}) {
  return _then(_Indexes(
lastModified: freezed == lastModified ? _self.lastModified : lastModified // ignore: cast_nullable_to_non_nullable
as DateTime?,indexes: null == indexes ? _self._indexes : indexes // ignore: cast_nullable_to_non_nullable
as List<IndexesIndex>,shortcut: null == shortcut ? _self._shortcut : shortcut // ignore: cast_nullable_to_non_nullable
as List<Artist>,child: null == child ? _self._child : child // ignore: cast_nullable_to_non_nullable
as List<Artist>,
  ));
}


}


/// @nodoc
mixin _$IndexesIndex {

 String? get name;@JsonKey(name: 'artist') List<Artist> get artists;
/// Create a copy of IndexesIndex
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IndexesIndexCopyWith<IndexesIndex> get copyWith => _$IndexesIndexCopyWithImpl<IndexesIndex>(this as IndexesIndex, _$identity);

  /// Serializes this IndexesIndex to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IndexesIndex&&(identical(other.name, name) || other.name == name)&&const DeepCollectionEquality().equals(other.artists, artists));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,const DeepCollectionEquality().hash(artists));

@override
String toString() {
  return 'IndexesIndex(name: $name, artists: $artists)';
}


}

/// @nodoc
abstract mixin class $IndexesIndexCopyWith<$Res>  {
  factory $IndexesIndexCopyWith(IndexesIndex value, $Res Function(IndexesIndex) _then) = _$IndexesIndexCopyWithImpl;
@useResult
$Res call({
 String? name,@JsonKey(name: 'artist') List<Artist> artists
});




}
/// @nodoc
class _$IndexesIndexCopyWithImpl<$Res>
    implements $IndexesIndexCopyWith<$Res> {
  _$IndexesIndexCopyWithImpl(this._self, this._then);

  final IndexesIndex _self;
  final $Res Function(IndexesIndex) _then;

/// Create a copy of IndexesIndex
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = freezed,Object? artists = null,}) {
  return _then(_self.copyWith(
name: freezed == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String?,artists: null == artists ? _self.artists : artists // ignore: cast_nullable_to_non_nullable
as List<Artist>,
  ));
}

}


/// Adds pattern-matching-related methods to [IndexesIndex].
extension IndexesIndexPatterns on IndexesIndex {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _IndexesIndex value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _IndexesIndex() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _IndexesIndex value)  $default,){
final _that = this;
switch (_that) {
case _IndexesIndex():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _IndexesIndex value)?  $default,){
final _that = this;
switch (_that) {
case _IndexesIndex() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? name, @JsonKey(name: 'artist')  List<Artist> artists)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _IndexesIndex() when $default != null:
return $default(_that.name,_that.artists);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? name, @JsonKey(name: 'artist')  List<Artist> artists)  $default,) {final _that = this;
switch (_that) {
case _IndexesIndex():
return $default(_that.name,_that.artists);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? name, @JsonKey(name: 'artist')  List<Artist> artists)?  $default,) {final _that = this;
switch (_that) {
case _IndexesIndex() when $default != null:
return $default(_that.name,_that.artists);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _IndexesIndex implements IndexesIndex {
  const _IndexesIndex({this.name, @JsonKey(name: 'artist') final  List<Artist> artists = const <Artist>[]}): _artists = artists;
  factory _IndexesIndex.fromJson(Map<String, dynamic> json) => _$IndexesIndexFromJson(json);

@override final  String? name;
 final  List<Artist> _artists;
@override@JsonKey(name: 'artist') List<Artist> get artists {
  if (_artists is EqualUnmodifiableListView) return _artists;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_artists);
}


/// Create a copy of IndexesIndex
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$IndexesIndexCopyWith<_IndexesIndex> get copyWith => __$IndexesIndexCopyWithImpl<_IndexesIndex>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$IndexesIndexToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _IndexesIndex&&(identical(other.name, name) || other.name == name)&&const DeepCollectionEquality().equals(other._artists, _artists));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,const DeepCollectionEquality().hash(_artists));

@override
String toString() {
  return 'IndexesIndex(name: $name, artists: $artists)';
}


}

/// @nodoc
abstract mixin class _$IndexesIndexCopyWith<$Res> implements $IndexesIndexCopyWith<$Res> {
  factory _$IndexesIndexCopyWith(_IndexesIndex value, $Res Function(_IndexesIndex) _then) = __$IndexesIndexCopyWithImpl;
@override @useResult
$Res call({
 String? name,@JsonKey(name: 'artist') List<Artist> artists
});




}
/// @nodoc
class __$IndexesIndexCopyWithImpl<$Res>
    implements _$IndexesIndexCopyWith<$Res> {
  __$IndexesIndexCopyWithImpl(this._self, this._then);

  final _IndexesIndex _self;
  final $Res Function(_IndexesIndex) _then;

/// Create a copy of IndexesIndex
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = freezed,Object? artists = null,}) {
  return _then(_IndexesIndex(
name: freezed == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String?,artists: null == artists ? _self._artists : artists // ignore: cast_nullable_to_non_nullable
as List<Artist>,
  ));
}


}

// dart format on
