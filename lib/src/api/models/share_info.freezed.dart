// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'share_info.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ShareInfo {

 String get id; String? get url; String? get description; DateTime? get expires; DateTime? get created;
/// Create a copy of ShareInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ShareInfoCopyWith<ShareInfo> get copyWith => _$ShareInfoCopyWithImpl<ShareInfo>(this as ShareInfo, _$identity);

  /// Serializes this ShareInfo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ShareInfo&&(identical(other.id, id) || other.id == id)&&(identical(other.url, url) || other.url == url)&&(identical(other.description, description) || other.description == description)&&(identical(other.expires, expires) || other.expires == expires)&&(identical(other.created, created) || other.created == created));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,url,description,expires,created);

@override
String toString() {
  return 'ShareInfo(id: $id, url: $url, description: $description, expires: $expires, created: $created)';
}


}

/// @nodoc
abstract mixin class $ShareInfoCopyWith<$Res>  {
  factory $ShareInfoCopyWith(ShareInfo value, $Res Function(ShareInfo) _then) = _$ShareInfoCopyWithImpl;
@useResult
$Res call({
 String id, String? url, String? description, DateTime? expires, DateTime? created
});




}
/// @nodoc
class _$ShareInfoCopyWithImpl<$Res>
    implements $ShareInfoCopyWith<$Res> {
  _$ShareInfoCopyWithImpl(this._self, this._then);

  final ShareInfo _self;
  final $Res Function(ShareInfo) _then;

/// Create a copy of ShareInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? url = freezed,Object? description = freezed,Object? expires = freezed,Object? created = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,url: freezed == url ? _self.url : url // ignore: cast_nullable_to_non_nullable
as String?,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,expires: freezed == expires ? _self.expires : expires // ignore: cast_nullable_to_non_nullable
as DateTime?,created: freezed == created ? _self.created : created // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [ShareInfo].
extension ShareInfoPatterns on ShareInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ShareInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ShareInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ShareInfo value)  $default,){
final _that = this;
switch (_that) {
case _ShareInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ShareInfo value)?  $default,){
final _that = this;
switch (_that) {
case _ShareInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String? url,  String? description,  DateTime? expires,  DateTime? created)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ShareInfo() when $default != null:
return $default(_that.id,_that.url,_that.description,_that.expires,_that.created);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String? url,  String? description,  DateTime? expires,  DateTime? created)  $default,) {final _that = this;
switch (_that) {
case _ShareInfo():
return $default(_that.id,_that.url,_that.description,_that.expires,_that.created);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String? url,  String? description,  DateTime? expires,  DateTime? created)?  $default,) {final _that = this;
switch (_that) {
case _ShareInfo() when $default != null:
return $default(_that.id,_that.url,_that.description,_that.expires,_that.created);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ShareInfo implements ShareInfo {
  const _ShareInfo({required this.id, this.url, this.description, this.expires, this.created});
  factory _ShareInfo.fromJson(Map<String, dynamic> json) => _$ShareInfoFromJson(json);

@override final  String id;
@override final  String? url;
@override final  String? description;
@override final  DateTime? expires;
@override final  DateTime? created;

/// Create a copy of ShareInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ShareInfoCopyWith<_ShareInfo> get copyWith => __$ShareInfoCopyWithImpl<_ShareInfo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ShareInfoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ShareInfo&&(identical(other.id, id) || other.id == id)&&(identical(other.url, url) || other.url == url)&&(identical(other.description, description) || other.description == description)&&(identical(other.expires, expires) || other.expires == expires)&&(identical(other.created, created) || other.created == created));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,url,description,expires,created);

@override
String toString() {
  return 'ShareInfo(id: $id, url: $url, description: $description, expires: $expires, created: $created)';
}


}

/// @nodoc
abstract mixin class _$ShareInfoCopyWith<$Res> implements $ShareInfoCopyWith<$Res> {
  factory _$ShareInfoCopyWith(_ShareInfo value, $Res Function(_ShareInfo) _then) = __$ShareInfoCopyWithImpl;
@override @useResult
$Res call({
 String id, String? url, String? description, DateTime? expires, DateTime? created
});




}
/// @nodoc
class __$ShareInfoCopyWithImpl<$Res>
    implements _$ShareInfoCopyWith<$Res> {
  __$ShareInfoCopyWithImpl(this._self, this._then);

  final _ShareInfo _self;
  final $Res Function(_ShareInfo) _then;

/// Create a copy of ShareInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? url = freezed,Object? description = freezed,Object? expires = freezed,Object? created = freezed,}) {
  return _then(_ShareInfo(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,url: freezed == url ? _self.url : url // ignore: cast_nullable_to_non_nullable
as String?,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,expires: freezed == expires ? _self.expires : expires // ignore: cast_nullable_to_non_nullable
as DateTime?,created: freezed == created ? _self.created : created // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
