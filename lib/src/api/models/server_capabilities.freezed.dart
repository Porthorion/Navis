// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'server_capabilities.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$OpenSubsonicExtension {

 String get name; List<String> get versions;
/// Create a copy of OpenSubsonicExtension
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$OpenSubsonicExtensionCopyWith<OpenSubsonicExtension> get copyWith => _$OpenSubsonicExtensionCopyWithImpl<OpenSubsonicExtension>(this as OpenSubsonicExtension, _$identity);

  /// Serializes this OpenSubsonicExtension to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as OpenSubsonicExtension;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OpenSubsonicExtension&&(identical(other.name, _this.name) || other.name == _this.name)&&const DeepCollectionEquality().equals(other.versions, _this.versions));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as OpenSubsonicExtension;
  return Object.hash(runtimeType,_this.name,const DeepCollectionEquality().hash(_this.versions));
}

@override
String toString() {
  final _this = this as OpenSubsonicExtension;
  return 'OpenSubsonicExtension(name: ${_this.name}, versions: ${_this.versions})';
}


}

/// @nodoc
abstract mixin class $OpenSubsonicExtensionCopyWith<$Res>  {
  factory $OpenSubsonicExtensionCopyWith(OpenSubsonicExtension value, $Res Function(OpenSubsonicExtension) _then) = _$OpenSubsonicExtensionCopyWithImpl;
@useResult
$Res call({
 String name, List<String> versions
});




}
/// @nodoc
class _$OpenSubsonicExtensionCopyWithImpl<$Res>
    implements $OpenSubsonicExtensionCopyWith<$Res> {
  _$OpenSubsonicExtensionCopyWithImpl(this._self, this._then);

  final OpenSubsonicExtension _self;
  final $Res Function(OpenSubsonicExtension) _then;

/// Create a copy of OpenSubsonicExtension
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? versions = null,}) {
  return _then(OpenSubsonicExtension(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,versions: null == versions ? _self.versions : versions // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}

}


/// Adds pattern-matching-related methods to [OpenSubsonicExtension].
extension OpenSubsonicExtensionPatterns on OpenSubsonicExtension {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _OpenSubsonicExtension value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _OpenSubsonicExtension() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _OpenSubsonicExtension value)  $default,){
final _that = this;
switch (_that) {
case _OpenSubsonicExtension():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _OpenSubsonicExtension value)?  $default,){
final _that = this;
switch (_that) {
case _OpenSubsonicExtension() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  List<String> versions)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _OpenSubsonicExtension() when $default != null:
return $default(_that.name,_that.versions);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  List<String> versions)  $default,) {final _that = this;
switch (_that) {
case _OpenSubsonicExtension():
return $default(_that.name,_that.versions);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  List<String> versions)?  $default,) {final _that = this;
switch (_that) {
case _OpenSubsonicExtension() when $default != null:
return $default(_that.name,_that.versions);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _OpenSubsonicExtension implements OpenSubsonicExtension {
  const _OpenSubsonicExtension({required this.name,  List<String> versions = const <String>[]}): _versions = versions;
  factory _OpenSubsonicExtension.fromJson(Map<String, dynamic> json) => _$OpenSubsonicExtensionFromJson(json);

@override final  String name;
 final  List<String> _versions;
@override@JsonKey() List<String> get versions {
  if (_versions is EqualUnmodifiableListView) return _versions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_versions);
}


/// Create a copy of OpenSubsonicExtension
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$OpenSubsonicExtensionCopyWith<_OpenSubsonicExtension> get copyWith => __$OpenSubsonicExtensionCopyWithImpl<_OpenSubsonicExtension>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$OpenSubsonicExtensionToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _OpenSubsonicExtension&&(identical(other.name, name) || other.name == name)&&const DeepCollectionEquality().equals(other.versions, _versions));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,name,const DeepCollectionEquality().hash(_versions));
}

@override
String toString() {
    return 'OpenSubsonicExtension(name: $name, versions: $versions)';
}


}

/// @nodoc
abstract mixin class _$OpenSubsonicExtensionCopyWith<$Res> implements $OpenSubsonicExtensionCopyWith<$Res> {
  factory _$OpenSubsonicExtensionCopyWith(_OpenSubsonicExtension value, $Res Function(_OpenSubsonicExtension) _then) = __$OpenSubsonicExtensionCopyWithImpl;
@override @useResult
$Res call({
 String name, List<String> versions
});




}
/// @nodoc
class __$OpenSubsonicExtensionCopyWithImpl<$Res>
    implements _$OpenSubsonicExtensionCopyWith<$Res> {
  __$OpenSubsonicExtensionCopyWithImpl(this._self, this._then);

  final _OpenSubsonicExtension _self;
  final $Res Function(_OpenSubsonicExtension) _then;

/// Create a copy of OpenSubsonicExtension
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? versions = null,}) {
  return _then(_OpenSubsonicExtension(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,versions: null == versions ? _self._versions : versions // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}


/// @nodoc
mixin _$ServerCapabilities {

 List<OpenSubsonicExtension> get extensions;
/// Create a copy of ServerCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ServerCapabilitiesCopyWith<ServerCapabilities> get copyWith => _$ServerCapabilitiesCopyWithImpl<ServerCapabilities>(this as ServerCapabilities, _$identity);

  /// Serializes this ServerCapabilities to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as ServerCapabilities;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ServerCapabilities&&const DeepCollectionEquality().equals(other.extensions, _this.extensions));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as ServerCapabilities;
  return Object.hash(runtimeType,const DeepCollectionEquality().hash(_this.extensions));
}

@override
String toString() {
  final _this = this as ServerCapabilities;
  return 'ServerCapabilities(extensions: ${_this.extensions})';
}


}

/// @nodoc
abstract mixin class $ServerCapabilitiesCopyWith<$Res>  {
  factory $ServerCapabilitiesCopyWith(ServerCapabilities value, $Res Function(ServerCapabilities) _then) = _$ServerCapabilitiesCopyWithImpl;
@useResult
$Res call({
 List<OpenSubsonicExtension> extensions
});




}
/// @nodoc
class _$ServerCapabilitiesCopyWithImpl<$Res>
    implements $ServerCapabilitiesCopyWith<$Res> {
  _$ServerCapabilitiesCopyWithImpl(this._self, this._then);

  final ServerCapabilities _self;
  final $Res Function(ServerCapabilities) _then;

/// Create a copy of ServerCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? extensions = null,}) {
  return _then(ServerCapabilities(
extensions: null == extensions ? _self.extensions : extensions // ignore: cast_nullable_to_non_nullable
as List<OpenSubsonicExtension>,
  ));
}

}


/// Adds pattern-matching-related methods to [ServerCapabilities].
extension ServerCapabilitiesPatterns on ServerCapabilities {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ServerCapabilities value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ServerCapabilities() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ServerCapabilities value)  $default,){
final _that = this;
switch (_that) {
case _ServerCapabilities():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ServerCapabilities value)?  $default,){
final _that = this;
switch (_that) {
case _ServerCapabilities() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<OpenSubsonicExtension> extensions)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ServerCapabilities() when $default != null:
return $default(_that.extensions);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<OpenSubsonicExtension> extensions)  $default,) {final _that = this;
switch (_that) {
case _ServerCapabilities():
return $default(_that.extensions);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<OpenSubsonicExtension> extensions)?  $default,) {final _that = this;
switch (_that) {
case _ServerCapabilities() when $default != null:
return $default(_that.extensions);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ServerCapabilities extends ServerCapabilities {
  const _ServerCapabilities({ List<OpenSubsonicExtension> extensions = const <OpenSubsonicExtension>[]}): _extensions = extensions,super._();
  factory _ServerCapabilities.fromJson(Map<String, dynamic> json) => _$ServerCapabilitiesFromJson(json);

 final  List<OpenSubsonicExtension> _extensions;
@override@JsonKey() List<OpenSubsonicExtension> get extensions {
  if (_extensions is EqualUnmodifiableListView) return _extensions;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_extensions);
}


/// Create a copy of ServerCapabilities
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ServerCapabilitiesCopyWith<_ServerCapabilities> get copyWith => __$ServerCapabilitiesCopyWithImpl<_ServerCapabilities>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ServerCapabilitiesToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ServerCapabilities&&const DeepCollectionEquality().equals(other.extensions, _extensions));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,const DeepCollectionEquality().hash(_extensions));
}

@override
String toString() {
    return 'ServerCapabilities(extensions: $extensions)';
}


}

/// @nodoc
abstract mixin class _$ServerCapabilitiesCopyWith<$Res> implements $ServerCapabilitiesCopyWith<$Res> {
  factory _$ServerCapabilitiesCopyWith(_ServerCapabilities value, $Res Function(_ServerCapabilities) _then) = __$ServerCapabilitiesCopyWithImpl;
@override @useResult
$Res call({
 List<OpenSubsonicExtension> extensions
});




}
/// @nodoc
class __$ServerCapabilitiesCopyWithImpl<$Res>
    implements _$ServerCapabilitiesCopyWith<$Res> {
  __$ServerCapabilitiesCopyWithImpl(this._self, this._then);

  final _ServerCapabilities _self;
  final $Res Function(_ServerCapabilities) _then;

/// Create a copy of ServerCapabilities
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? extensions = null,}) {
  return _then(_ServerCapabilities(
extensions: null == extensions ? _self._extensions : extensions // ignore: cast_nullable_to_non_nullable
as List<OpenSubsonicExtension>,
  ));
}


}

// dart format on
