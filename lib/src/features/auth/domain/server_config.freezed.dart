// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'server_config.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ServerConfigModel {

 int? get id; String? get name; String get url; String get username; String get password; String get apiVersion; bool get useLegacyAuth; String? get capabilitiesJson; DateTime? get lastSynced; DateTime? get lastFullSyncedAt;
/// Create a copy of ServerConfigModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ServerConfigModelCopyWith<ServerConfigModel> get copyWith => _$ServerConfigModelCopyWithImpl<ServerConfigModel>(this as ServerConfigModel, _$identity);

  /// Serializes this ServerConfigModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as ServerConfigModel;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ServerConfigModel&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.name, _this.name) || other.name == _this.name)&&(identical(other.url, _this.url) || other.url == _this.url)&&(identical(other.username, _this.username) || other.username == _this.username)&&(identical(other.password, _this.password) || other.password == _this.password)&&(identical(other.apiVersion, _this.apiVersion) || other.apiVersion == _this.apiVersion)&&(identical(other.useLegacyAuth, _this.useLegacyAuth) || other.useLegacyAuth == _this.useLegacyAuth)&&(identical(other.capabilitiesJson, _this.capabilitiesJson) || other.capabilitiesJson == _this.capabilitiesJson)&&(identical(other.lastSynced, _this.lastSynced) || other.lastSynced == _this.lastSynced)&&(identical(other.lastFullSyncedAt, _this.lastFullSyncedAt) || other.lastFullSyncedAt == _this.lastFullSyncedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as ServerConfigModel;
  return Object.hash(runtimeType,_this.id,_this.name,_this.url,_this.username,_this.password,_this.apiVersion,_this.useLegacyAuth,_this.capabilitiesJson,_this.lastSynced,_this.lastFullSyncedAt);
}

@override
String toString() {
  final _this = this as ServerConfigModel;
  return 'ServerConfigModel(id: ${_this.id}, name: ${_this.name}, url: ${_this.url}, username: ${_this.username}, password: ${_this.password}, apiVersion: ${_this.apiVersion}, useLegacyAuth: ${_this.useLegacyAuth}, capabilitiesJson: ${_this.capabilitiesJson}, lastSynced: ${_this.lastSynced}, lastFullSyncedAt: ${_this.lastFullSyncedAt})';
}


}

/// @nodoc
abstract mixin class $ServerConfigModelCopyWith<$Res>  {
  factory $ServerConfigModelCopyWith(ServerConfigModel value, $Res Function(ServerConfigModel) _then) = _$ServerConfigModelCopyWithImpl;
@useResult
$Res call({
 int? id, String? name, String url, String username, String password, String apiVersion, bool useLegacyAuth, String? capabilitiesJson, DateTime? lastSynced, DateTime? lastFullSyncedAt
});




}
/// @nodoc
class _$ServerConfigModelCopyWithImpl<$Res>
    implements $ServerConfigModelCopyWith<$Res> {
  _$ServerConfigModelCopyWithImpl(this._self, this._then);

  final ServerConfigModel _self;
  final $Res Function(ServerConfigModel) _then;

/// Create a copy of ServerConfigModel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = freezed,Object? name = freezed,Object? url = null,Object? username = null,Object? password = null,Object? apiVersion = null,Object? useLegacyAuth = null,Object? capabilitiesJson = freezed,Object? lastSynced = freezed,Object? lastFullSyncedAt = freezed,}) {
  return _then(ServerConfigModel(
id: freezed == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int?,name: freezed == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String?,url: null == url ? _self.url : url // ignore: cast_nullable_to_non_nullable
as String,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,password: null == password ? _self.password : password // ignore: cast_nullable_to_non_nullable
as String,apiVersion: null == apiVersion ? _self.apiVersion : apiVersion // ignore: cast_nullable_to_non_nullable
as String,useLegacyAuth: null == useLegacyAuth ? _self.useLegacyAuth : useLegacyAuth // ignore: cast_nullable_to_non_nullable
as bool,capabilitiesJson: freezed == capabilitiesJson ? _self.capabilitiesJson : capabilitiesJson // ignore: cast_nullable_to_non_nullable
as String?,lastSynced: freezed == lastSynced ? _self.lastSynced : lastSynced // ignore: cast_nullable_to_non_nullable
as DateTime?,lastFullSyncedAt: freezed == lastFullSyncedAt ? _self.lastFullSyncedAt : lastFullSyncedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}

}


/// Adds pattern-matching-related methods to [ServerConfigModel].
extension ServerConfigModelPatterns on ServerConfigModel {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ServerConfigModel value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ServerConfigModel() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ServerConfigModel value)  $default,){
final _that = this;
switch (_that) {
case _ServerConfigModel():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ServerConfigModel value)?  $default,){
final _that = this;
switch (_that) {
case _ServerConfigModel() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int? id,  String? name,  String url,  String username,  String password,  String apiVersion,  bool useLegacyAuth,  String? capabilitiesJson,  DateTime? lastSynced,  DateTime? lastFullSyncedAt)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ServerConfigModel() when $default != null:
return $default(_that.id,_that.name,_that.url,_that.username,_that.password,_that.apiVersion,_that.useLegacyAuth,_that.capabilitiesJson,_that.lastSynced,_that.lastFullSyncedAt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int? id,  String? name,  String url,  String username,  String password,  String apiVersion,  bool useLegacyAuth,  String? capabilitiesJson,  DateTime? lastSynced,  DateTime? lastFullSyncedAt)  $default,) {final _that = this;
switch (_that) {
case _ServerConfigModel():
return $default(_that.id,_that.name,_that.url,_that.username,_that.password,_that.apiVersion,_that.useLegacyAuth,_that.capabilitiesJson,_that.lastSynced,_that.lastFullSyncedAt);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int? id,  String? name,  String url,  String username,  String password,  String apiVersion,  bool useLegacyAuth,  String? capabilitiesJson,  DateTime? lastSynced,  DateTime? lastFullSyncedAt)?  $default,) {final _that = this;
switch (_that) {
case _ServerConfigModel() when $default != null:
return $default(_that.id,_that.name,_that.url,_that.username,_that.password,_that.apiVersion,_that.useLegacyAuth,_that.capabilitiesJson,_that.lastSynced,_that.lastFullSyncedAt);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ServerConfigModel implements ServerConfigModel {
  const _ServerConfigModel({this.id, this.name, required this.url, required this.username, required this.password, required this.apiVersion, this.useLegacyAuth = false, this.capabilitiesJson, this.lastSynced, this.lastFullSyncedAt});
  factory _ServerConfigModel.fromJson(Map<String, dynamic> json) => _$ServerConfigModelFromJson(json);

@override final  int? id;
@override final  String? name;
@override final  String url;
@override final  String username;
@override final  String password;
@override final  String apiVersion;
@override@JsonKey() final  bool useLegacyAuth;
@override final  String? capabilitiesJson;
@override final  DateTime? lastSynced;
@override final  DateTime? lastFullSyncedAt;

/// Create a copy of ServerConfigModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ServerConfigModelCopyWith<_ServerConfigModel> get copyWith => __$ServerConfigModelCopyWithImpl<_ServerConfigModel>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ServerConfigModelToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ServerConfigModel&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.url, url) || other.url == url)&&(identical(other.username, username) || other.username == username)&&(identical(other.password, password) || other.password == password)&&(identical(other.apiVersion, apiVersion) || other.apiVersion == apiVersion)&&(identical(other.useLegacyAuth, useLegacyAuth) || other.useLegacyAuth == useLegacyAuth)&&(identical(other.capabilitiesJson, capabilitiesJson) || other.capabilitiesJson == capabilitiesJson)&&(identical(other.lastSynced, lastSynced) || other.lastSynced == lastSynced)&&(identical(other.lastFullSyncedAt, lastFullSyncedAt) || other.lastFullSyncedAt == lastFullSyncedAt));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,id,name,url,username,password,apiVersion,useLegacyAuth,capabilitiesJson,lastSynced,lastFullSyncedAt);
}

@override
String toString() {
    return 'ServerConfigModel(id: $id, name: $name, url: $url, username: $username, password: $password, apiVersion: $apiVersion, useLegacyAuth: $useLegacyAuth, capabilitiesJson: $capabilitiesJson, lastSynced: $lastSynced, lastFullSyncedAt: $lastFullSyncedAt)';
}


}

/// @nodoc
abstract mixin class _$ServerConfigModelCopyWith<$Res> implements $ServerConfigModelCopyWith<$Res> {
  factory _$ServerConfigModelCopyWith(_ServerConfigModel value, $Res Function(_ServerConfigModel) _then) = __$ServerConfigModelCopyWithImpl;
@override @useResult
$Res call({
 int? id, String? name, String url, String username, String password, String apiVersion, bool useLegacyAuth, String? capabilitiesJson, DateTime? lastSynced, DateTime? lastFullSyncedAt
});




}
/// @nodoc
class __$ServerConfigModelCopyWithImpl<$Res>
    implements _$ServerConfigModelCopyWith<$Res> {
  __$ServerConfigModelCopyWithImpl(this._self, this._then);

  final _ServerConfigModel _self;
  final $Res Function(_ServerConfigModel) _then;

/// Create a copy of ServerConfigModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = freezed,Object? name = freezed,Object? url = null,Object? username = null,Object? password = null,Object? apiVersion = null,Object? useLegacyAuth = null,Object? capabilitiesJson = freezed,Object? lastSynced = freezed,Object? lastFullSyncedAt = freezed,}) {
  return _then(_ServerConfigModel(
id: freezed == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int?,name: freezed == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String?,url: null == url ? _self.url : url // ignore: cast_nullable_to_non_nullable
as String,username: null == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String,password: null == password ? _self.password : password // ignore: cast_nullable_to_non_nullable
as String,apiVersion: null == apiVersion ? _self.apiVersion : apiVersion // ignore: cast_nullable_to_non_nullable
as String,useLegacyAuth: null == useLegacyAuth ? _self.useLegacyAuth : useLegacyAuth // ignore: cast_nullable_to_non_nullable
as bool,capabilitiesJson: freezed == capabilitiesJson ? _self.capabilitiesJson : capabilitiesJson // ignore: cast_nullable_to_non_nullable
as String?,lastSynced: freezed == lastSynced ? _self.lastSynced : lastSynced // ignore: cast_nullable_to_non_nullable
as DateTime?,lastFullSyncedAt: freezed == lastFullSyncedAt ? _self.lastFullSyncedAt : lastFullSyncedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,
  ));
}


}

// dart format on
