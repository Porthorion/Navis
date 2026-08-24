// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'subsonic_response.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SubsonicErrorResponse {

 int? get code; String? get message;
/// Create a copy of SubsonicErrorResponse
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SubsonicErrorResponseCopyWith<SubsonicErrorResponse> get copyWith => _$SubsonicErrorResponseCopyWithImpl<SubsonicErrorResponse>(this as SubsonicErrorResponse, _$identity);

  /// Serializes this SubsonicErrorResponse to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SubsonicErrorResponse&&(identical(other.code, code) || other.code == code)&&(identical(other.message, message) || other.message == message));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,code,message);

@override
String toString() {
  return 'SubsonicErrorResponse(code: $code, message: $message)';
}


}

/// @nodoc
abstract mixin class $SubsonicErrorResponseCopyWith<$Res>  {
  factory $SubsonicErrorResponseCopyWith(SubsonicErrorResponse value, $Res Function(SubsonicErrorResponse) _then) = _$SubsonicErrorResponseCopyWithImpl;
@useResult
$Res call({
 int? code, String? message
});




}
/// @nodoc
class _$SubsonicErrorResponseCopyWithImpl<$Res>
    implements $SubsonicErrorResponseCopyWith<$Res> {
  _$SubsonicErrorResponseCopyWithImpl(this._self, this._then);

  final SubsonicErrorResponse _self;
  final $Res Function(SubsonicErrorResponse) _then;

/// Create a copy of SubsonicErrorResponse
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? code = freezed,Object? message = freezed,}) {
  return _then(SubsonicErrorResponse(
code: freezed == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as int?,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [SubsonicErrorResponse].
extension SubsonicErrorResponsePatterns on SubsonicErrorResponse {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SubsonicErrorResponse value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SubsonicErrorResponse() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SubsonicErrorResponse value)  $default,){
final _that = this;
switch (_that) {
case _SubsonicErrorResponse():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SubsonicErrorResponse value)?  $default,){
final _that = this;
switch (_that) {
case _SubsonicErrorResponse() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int? code,  String? message)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SubsonicErrorResponse() when $default != null:
return $default(_that.code,_that.message);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int? code,  String? message)  $default,) {final _that = this;
switch (_that) {
case _SubsonicErrorResponse():
return $default(_that.code,_that.message);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int? code,  String? message)?  $default,) {final _that = this;
switch (_that) {
case _SubsonicErrorResponse() when $default != null:
return $default(_that.code,_that.message);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SubsonicErrorResponse implements SubsonicErrorResponse {
  const _SubsonicErrorResponse({this.code, this.message});
  factory _SubsonicErrorResponse.fromJson(Map<String, dynamic> json) => _$SubsonicErrorResponseFromJson(json);

@override final  int? code;
@override final  String? message;

/// Create a copy of SubsonicErrorResponse
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SubsonicErrorResponseCopyWith<_SubsonicErrorResponse> get copyWith => __$SubsonicErrorResponseCopyWithImpl<_SubsonicErrorResponse>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SubsonicErrorResponseToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SubsonicErrorResponse&&(identical(other.code, code) || other.code == code)&&(identical(other.message, message) || other.message == message));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,code,message);

@override
String toString() {
  return 'SubsonicErrorResponse(code: $code, message: $message)';
}


}

/// @nodoc
abstract mixin class _$SubsonicErrorResponseCopyWith<$Res> implements $SubsonicErrorResponseCopyWith<$Res> {
  factory _$SubsonicErrorResponseCopyWith(_SubsonicErrorResponse value, $Res Function(_SubsonicErrorResponse) _then) = __$SubsonicErrorResponseCopyWithImpl;
@override @useResult
$Res call({
 int? code, String? message
});




}
/// @nodoc
class __$SubsonicErrorResponseCopyWithImpl<$Res>
    implements _$SubsonicErrorResponseCopyWith<$Res> {
  __$SubsonicErrorResponseCopyWithImpl(this._self, this._then);

  final _SubsonicErrorResponse _self;
  final $Res Function(_SubsonicErrorResponse) _then;

/// Create a copy of SubsonicErrorResponse
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? code = freezed,Object? message = freezed,}) {
  return _then(_SubsonicErrorResponse(
code: freezed == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as int?,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$SubsonicResponse<T> {

 String get status; String? get version; String? get type; String? get serverVersion; bool? get openSubsonic; SubsonicErrorResponse? get error; T? get data;
/// Create a copy of SubsonicResponse
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SubsonicResponseCopyWith<T, SubsonicResponse<T>> get copyWith => _$SubsonicResponseCopyWithImpl<T, SubsonicResponse<T>>(this as SubsonicResponse<T>, _$identity);

  /// Serializes this SubsonicResponse to a JSON map.
  Map<String, dynamic> toJson(Object? Function(T) toJsonT);


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SubsonicResponse<T>&&(identical(other.status, status) || other.status == status)&&(identical(other.version, version) || other.version == version)&&(identical(other.type, type) || other.type == type)&&(identical(other.serverVersion, serverVersion) || other.serverVersion == serverVersion)&&(identical(other.openSubsonic, openSubsonic) || other.openSubsonic == openSubsonic)&&(identical(other.error, error) || other.error == error)&&const DeepCollectionEquality().equals(other.data, data));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,status,version,type,serverVersion,openSubsonic,error,const DeepCollectionEquality().hash(data));

@override
String toString() {
  return 'SubsonicResponse<$T>(status: $status, version: $version, type: $type, serverVersion: $serverVersion, openSubsonic: $openSubsonic, error: $error, data: $data)';
}


}

/// @nodoc
abstract mixin class $SubsonicResponseCopyWith<T,$Res>  {
  factory $SubsonicResponseCopyWith(SubsonicResponse<T> value, $Res Function(SubsonicResponse<T>) _then) = _$SubsonicResponseCopyWithImpl;
@useResult
$Res call({
 String status, String? version, String? type, String? serverVersion, bool? openSubsonic, SubsonicErrorResponse? error, T? data
});


$SubsonicErrorResponseCopyWith<$Res>? get error;

}
/// @nodoc
class _$SubsonicResponseCopyWithImpl<T,$Res>
    implements $SubsonicResponseCopyWith<T, $Res> {
  _$SubsonicResponseCopyWithImpl(this._self, this._then);

  final SubsonicResponse<T> _self;
  final $Res Function(SubsonicResponse<T>) _then;

/// Create a copy of SubsonicResponse
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? status = null,Object? version = freezed,Object? type = freezed,Object? serverVersion = freezed,Object? openSubsonic = freezed,Object? error = freezed,Object? data = freezed,}) {
  return _then(SubsonicResponse(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,version: freezed == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String?,type: freezed == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String?,serverVersion: freezed == serverVersion ? _self.serverVersion : serverVersion // ignore: cast_nullable_to_non_nullable
as String?,openSubsonic: freezed == openSubsonic ? _self.openSubsonic : openSubsonic // ignore: cast_nullable_to_non_nullable
as bool?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as SubsonicErrorResponse?,data: freezed == data ? _self.data : data // ignore: cast_nullable_to_non_nullable
as T?,
  ));
}
/// Create a copy of SubsonicResponse
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SubsonicErrorResponseCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $SubsonicErrorResponseCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// Adds pattern-matching-related methods to [SubsonicResponse].
extension SubsonicResponsePatterns<T> on SubsonicResponse<T> {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SubsonicResponse<T> value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SubsonicResponse() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SubsonicResponse<T> value)  $default,){
final _that = this;
switch (_that) {
case _SubsonicResponse():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SubsonicResponse<T> value)?  $default,){
final _that = this;
switch (_that) {
case _SubsonicResponse() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String status,  String? version,  String? type,  String? serverVersion,  bool? openSubsonic,  SubsonicErrorResponse? error,  T? data)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SubsonicResponse() when $default != null:
return $default(_that.status,_that.version,_that.type,_that.serverVersion,_that.openSubsonic,_that.error,_that.data);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String status,  String? version,  String? type,  String? serverVersion,  bool? openSubsonic,  SubsonicErrorResponse? error,  T? data)  $default,) {final _that = this;
switch (_that) {
case _SubsonicResponse():
return $default(_that.status,_that.version,_that.type,_that.serverVersion,_that.openSubsonic,_that.error,_that.data);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String status,  String? version,  String? type,  String? serverVersion,  bool? openSubsonic,  SubsonicErrorResponse? error,  T? data)?  $default,) {final _that = this;
switch (_that) {
case _SubsonicResponse() when $default != null:
return $default(_that.status,_that.version,_that.type,_that.serverVersion,_that.openSubsonic,_that.error,_that.data);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable(genericArgumentFactories: true)

class _SubsonicResponse<T> implements SubsonicResponse<T> {
  const _SubsonicResponse({required this.status, this.version, this.type, this.serverVersion, this.openSubsonic, this.error, this.data});
  factory _SubsonicResponse.fromJson(Map<String, dynamic> json,T Function(Object?) fromJsonT) => _$SubsonicResponseFromJson(json,fromJsonT);

@override final  String status;
@override final  String? version;
@override final  String? type;
@override final  String? serverVersion;
@override final  bool? openSubsonic;
@override final  SubsonicErrorResponse? error;
@override final  T? data;

/// Create a copy of SubsonicResponse
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SubsonicResponseCopyWith<T, _SubsonicResponse<T>> get copyWith => __$SubsonicResponseCopyWithImpl<T, _SubsonicResponse<T>>(this, _$identity);

@override
Map<String, dynamic> toJson(Object? Function(T) toJsonT) {
  return _$SubsonicResponseToJson<T>(this, toJsonT);
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SubsonicResponse<T>&&(identical(other.status, status) || other.status == status)&&(identical(other.version, version) || other.version == version)&&(identical(other.type, type) || other.type == type)&&(identical(other.serverVersion, serverVersion) || other.serverVersion == serverVersion)&&(identical(other.openSubsonic, openSubsonic) || other.openSubsonic == openSubsonic)&&(identical(other.error, error) || other.error == error)&&const DeepCollectionEquality().equals(other.data, data));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,status,version,type,serverVersion,openSubsonic,error,const DeepCollectionEquality().hash(data));

@override
String toString() {
  return 'SubsonicResponse<$T>(status: $status, version: $version, type: $type, serverVersion: $serverVersion, openSubsonic: $openSubsonic, error: $error, data: $data)';
}


}

/// @nodoc
abstract mixin class _$SubsonicResponseCopyWith<T,$Res> implements $SubsonicResponseCopyWith<T, $Res> {
  factory _$SubsonicResponseCopyWith(_SubsonicResponse<T> value, $Res Function(_SubsonicResponse<T>) _then) = __$SubsonicResponseCopyWithImpl;
@override @useResult
$Res call({
 String status, String? version, String? type, String? serverVersion, bool? openSubsonic, SubsonicErrorResponse? error, T? data
});


@override $SubsonicErrorResponseCopyWith<$Res>? get error;

}
/// @nodoc
class __$SubsonicResponseCopyWithImpl<T,$Res>
    implements _$SubsonicResponseCopyWith<T, $Res> {
  __$SubsonicResponseCopyWithImpl(this._self, this._then);

  final _SubsonicResponse<T> _self;
  final $Res Function(_SubsonicResponse<T>) _then;

/// Create a copy of SubsonicResponse
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? status = null,Object? version = freezed,Object? type = freezed,Object? serverVersion = freezed,Object? openSubsonic = freezed,Object? error = freezed,Object? data = freezed,}) {
  return _then(_SubsonicResponse<T>(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,version: freezed == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String?,type: freezed == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as String?,serverVersion: freezed == serverVersion ? _self.serverVersion : serverVersion // ignore: cast_nullable_to_non_nullable
as String?,openSubsonic: freezed == openSubsonic ? _self.openSubsonic : openSubsonic // ignore: cast_nullable_to_non_nullable
as bool?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as SubsonicErrorResponse?,data: freezed == data ? _self.data : data // ignore: cast_nullable_to_non_nullable
as T?,
  ));
}

/// Create a copy of SubsonicResponse
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SubsonicErrorResponseCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $SubsonicErrorResponseCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}

// dart format on
