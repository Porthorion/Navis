// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'internet_radio_station.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$InternetRadioStation {

 String get id; String get name; String get streamUrl; String? get homePageUrl;
/// Create a copy of InternetRadioStation
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$InternetRadioStationCopyWith<InternetRadioStation> get copyWith => _$InternetRadioStationCopyWithImpl<InternetRadioStation>(this as InternetRadioStation, _$identity);

  /// Serializes this InternetRadioStation to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is InternetRadioStation&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.streamUrl, streamUrl) || other.streamUrl == streamUrl)&&(identical(other.homePageUrl, homePageUrl) || other.homePageUrl == homePageUrl));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,streamUrl,homePageUrl);

@override
String toString() {
  return 'InternetRadioStation(id: $id, name: $name, streamUrl: $streamUrl, homePageUrl: $homePageUrl)';
}


}

/// @nodoc
abstract mixin class $InternetRadioStationCopyWith<$Res>  {
  factory $InternetRadioStationCopyWith(InternetRadioStation value, $Res Function(InternetRadioStation) _then) = _$InternetRadioStationCopyWithImpl;
@useResult
$Res call({
 String id, String name, String streamUrl, String? homePageUrl
});




}
/// @nodoc
class _$InternetRadioStationCopyWithImpl<$Res>
    implements $InternetRadioStationCopyWith<$Res> {
  _$InternetRadioStationCopyWithImpl(this._self, this._then);

  final InternetRadioStation _self;
  final $Res Function(InternetRadioStation) _then;

/// Create a copy of InternetRadioStation
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? streamUrl = null,Object? homePageUrl = freezed,}) {
  return _then(InternetRadioStation(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,streamUrl: null == streamUrl ? _self.streamUrl : streamUrl // ignore: cast_nullable_to_non_nullable
as String,homePageUrl: freezed == homePageUrl ? _self.homePageUrl : homePageUrl // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [InternetRadioStation].
extension InternetRadioStationPatterns on InternetRadioStation {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _InternetRadioStation value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _InternetRadioStation() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _InternetRadioStation value)  $default,){
final _that = this;
switch (_that) {
case _InternetRadioStation():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _InternetRadioStation value)?  $default,){
final _that = this;
switch (_that) {
case _InternetRadioStation() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String streamUrl,  String? homePageUrl)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _InternetRadioStation() when $default != null:
return $default(_that.id,_that.name,_that.streamUrl,_that.homePageUrl);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String streamUrl,  String? homePageUrl)  $default,) {final _that = this;
switch (_that) {
case _InternetRadioStation():
return $default(_that.id,_that.name,_that.streamUrl,_that.homePageUrl);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String streamUrl,  String? homePageUrl)?  $default,) {final _that = this;
switch (_that) {
case _InternetRadioStation() when $default != null:
return $default(_that.id,_that.name,_that.streamUrl,_that.homePageUrl);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _InternetRadioStation implements InternetRadioStation {
  const _InternetRadioStation({required this.id, required this.name, required this.streamUrl, this.homePageUrl});
  factory _InternetRadioStation.fromJson(Map<String, dynamic> json) => _$InternetRadioStationFromJson(json);

@override final  String id;
@override final  String name;
@override final  String streamUrl;
@override final  String? homePageUrl;

/// Create a copy of InternetRadioStation
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$InternetRadioStationCopyWith<_InternetRadioStation> get copyWith => __$InternetRadioStationCopyWithImpl<_InternetRadioStation>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$InternetRadioStationToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _InternetRadioStation&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.streamUrl, streamUrl) || other.streamUrl == streamUrl)&&(identical(other.homePageUrl, homePageUrl) || other.homePageUrl == homePageUrl));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,streamUrl,homePageUrl);

@override
String toString() {
  return 'InternetRadioStation(id: $id, name: $name, streamUrl: $streamUrl, homePageUrl: $homePageUrl)';
}


}

/// @nodoc
abstract mixin class _$InternetRadioStationCopyWith<$Res> implements $InternetRadioStationCopyWith<$Res> {
  factory _$InternetRadioStationCopyWith(_InternetRadioStation value, $Res Function(_InternetRadioStation) _then) = __$InternetRadioStationCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String streamUrl, String? homePageUrl
});




}
/// @nodoc
class __$InternetRadioStationCopyWithImpl<$Res>
    implements _$InternetRadioStationCopyWith<$Res> {
  __$InternetRadioStationCopyWithImpl(this._self, this._then);

  final _InternetRadioStation _self;
  final $Res Function(_InternetRadioStation) _then;

/// Create a copy of InternetRadioStation
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? streamUrl = null,Object? homePageUrl = freezed,}) {
  return _then(_InternetRadioStation(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,streamUrl: null == streamUrl ? _self.streamUrl : streamUrl // ignore: cast_nullable_to_non_nullable
as String,homePageUrl: freezed == homePageUrl ? _self.homePageUrl : homePageUrl // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
