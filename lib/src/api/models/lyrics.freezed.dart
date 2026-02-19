// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'lyrics.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$LyricLine {

 int? get start; int? get duration; String? get value;
/// Create a copy of LyricLine
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$LyricLineCopyWith<LyricLine> get copyWith => _$LyricLineCopyWithImpl<LyricLine>(this as LyricLine, _$identity);

  /// Serializes this LyricLine to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is LyricLine&&(identical(other.start, start) || other.start == start)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.value, value) || other.value == value));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,start,duration,value);

@override
String toString() {
  return 'LyricLine(start: $start, duration: $duration, value: $value)';
}


}

/// @nodoc
abstract mixin class $LyricLineCopyWith<$Res>  {
  factory $LyricLineCopyWith(LyricLine value, $Res Function(LyricLine) _then) = _$LyricLineCopyWithImpl;
@useResult
$Res call({
 int? start, int? duration, String? value
});




}
/// @nodoc
class _$LyricLineCopyWithImpl<$Res>
    implements $LyricLineCopyWith<$Res> {
  _$LyricLineCopyWithImpl(this._self, this._then);

  final LyricLine _self;
  final $Res Function(LyricLine) _then;

/// Create a copy of LyricLine
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? start = freezed,Object? duration = freezed,Object? value = freezed,}) {
  return _then(_self.copyWith(
start: freezed == start ? _self.start : start // ignore: cast_nullable_to_non_nullable
as int?,duration: freezed == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as int?,value: freezed == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [LyricLine].
extension LyricLinePatterns on LyricLine {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _LyricLine value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _LyricLine() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _LyricLine value)  $default,){
final _that = this;
switch (_that) {
case _LyricLine():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _LyricLine value)?  $default,){
final _that = this;
switch (_that) {
case _LyricLine() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int? start,  int? duration,  String? value)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _LyricLine() when $default != null:
return $default(_that.start,_that.duration,_that.value);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int? start,  int? duration,  String? value)  $default,) {final _that = this;
switch (_that) {
case _LyricLine():
return $default(_that.start,_that.duration,_that.value);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int? start,  int? duration,  String? value)?  $default,) {final _that = this;
switch (_that) {
case _LyricLine() when $default != null:
return $default(_that.start,_that.duration,_that.value);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _LyricLine implements LyricLine {
  const _LyricLine({this.start, this.duration, this.value});
  factory _LyricLine.fromJson(Map<String, dynamic> json) => _$LyricLineFromJson(json);

@override final  int? start;
@override final  int? duration;
@override final  String? value;

/// Create a copy of LyricLine
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$LyricLineCopyWith<_LyricLine> get copyWith => __$LyricLineCopyWithImpl<_LyricLine>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$LyricLineToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _LyricLine&&(identical(other.start, start) || other.start == start)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.value, value) || other.value == value));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,start,duration,value);

@override
String toString() {
  return 'LyricLine(start: $start, duration: $duration, value: $value)';
}


}

/// @nodoc
abstract mixin class _$LyricLineCopyWith<$Res> implements $LyricLineCopyWith<$Res> {
  factory _$LyricLineCopyWith(_LyricLine value, $Res Function(_LyricLine) _then) = __$LyricLineCopyWithImpl;
@override @useResult
$Res call({
 int? start, int? duration, String? value
});




}
/// @nodoc
class __$LyricLineCopyWithImpl<$Res>
    implements _$LyricLineCopyWith<$Res> {
  __$LyricLineCopyWithImpl(this._self, this._then);

  final _LyricLine _self;
  final $Res Function(_LyricLine) _then;

/// Create a copy of LyricLine
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? start = freezed,Object? duration = freezed,Object? value = freezed,}) {
  return _then(_LyricLine(
start: freezed == start ? _self.start : start // ignore: cast_nullable_to_non_nullable
as int?,duration: freezed == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as int?,value: freezed == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$StructuredLyrics {

 String? get lang; bool? get synced; List<LyricLine> get line;
/// Create a copy of StructuredLyrics
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$StructuredLyricsCopyWith<StructuredLyrics> get copyWith => _$StructuredLyricsCopyWithImpl<StructuredLyrics>(this as StructuredLyrics, _$identity);

  /// Serializes this StructuredLyrics to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StructuredLyrics&&(identical(other.lang, lang) || other.lang == lang)&&(identical(other.synced, synced) || other.synced == synced)&&const DeepCollectionEquality().equals(other.line, line));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,lang,synced,const DeepCollectionEquality().hash(line));

@override
String toString() {
  return 'StructuredLyrics(lang: $lang, synced: $synced, line: $line)';
}


}

/// @nodoc
abstract mixin class $StructuredLyricsCopyWith<$Res>  {
  factory $StructuredLyricsCopyWith(StructuredLyrics value, $Res Function(StructuredLyrics) _then) = _$StructuredLyricsCopyWithImpl;
@useResult
$Res call({
 String? lang, bool? synced, List<LyricLine> line
});




}
/// @nodoc
class _$StructuredLyricsCopyWithImpl<$Res>
    implements $StructuredLyricsCopyWith<$Res> {
  _$StructuredLyricsCopyWithImpl(this._self, this._then);

  final StructuredLyrics _self;
  final $Res Function(StructuredLyrics) _then;

/// Create a copy of StructuredLyrics
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? lang = freezed,Object? synced = freezed,Object? line = null,}) {
  return _then(_self.copyWith(
lang: freezed == lang ? _self.lang : lang // ignore: cast_nullable_to_non_nullable
as String?,synced: freezed == synced ? _self.synced : synced // ignore: cast_nullable_to_non_nullable
as bool?,line: null == line ? _self.line : line // ignore: cast_nullable_to_non_nullable
as List<LyricLine>,
  ));
}

}


/// Adds pattern-matching-related methods to [StructuredLyrics].
extension StructuredLyricsPatterns on StructuredLyrics {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _StructuredLyrics value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _StructuredLyrics() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _StructuredLyrics value)  $default,){
final _that = this;
switch (_that) {
case _StructuredLyrics():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _StructuredLyrics value)?  $default,){
final _that = this;
switch (_that) {
case _StructuredLyrics() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String? lang,  bool? synced,  List<LyricLine> line)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _StructuredLyrics() when $default != null:
return $default(_that.lang,_that.synced,_that.line);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String? lang,  bool? synced,  List<LyricLine> line)  $default,) {final _that = this;
switch (_that) {
case _StructuredLyrics():
return $default(_that.lang,_that.synced,_that.line);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String? lang,  bool? synced,  List<LyricLine> line)?  $default,) {final _that = this;
switch (_that) {
case _StructuredLyrics() when $default != null:
return $default(_that.lang,_that.synced,_that.line);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _StructuredLyrics implements StructuredLyrics {
  const _StructuredLyrics({this.lang, this.synced, final  List<LyricLine> line = const <LyricLine>[]}): _line = line;
  factory _StructuredLyrics.fromJson(Map<String, dynamic> json) => _$StructuredLyricsFromJson(json);

@override final  String? lang;
@override final  bool? synced;
 final  List<LyricLine> _line;
@override@JsonKey() List<LyricLine> get line {
  if (_line is EqualUnmodifiableListView) return _line;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_line);
}


/// Create a copy of StructuredLyrics
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$StructuredLyricsCopyWith<_StructuredLyrics> get copyWith => __$StructuredLyricsCopyWithImpl<_StructuredLyrics>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$StructuredLyricsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _StructuredLyrics&&(identical(other.lang, lang) || other.lang == lang)&&(identical(other.synced, synced) || other.synced == synced)&&const DeepCollectionEquality().equals(other._line, _line));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,lang,synced,const DeepCollectionEquality().hash(_line));

@override
String toString() {
  return 'StructuredLyrics(lang: $lang, synced: $synced, line: $line)';
}


}

/// @nodoc
abstract mixin class _$StructuredLyricsCopyWith<$Res> implements $StructuredLyricsCopyWith<$Res> {
  factory _$StructuredLyricsCopyWith(_StructuredLyrics value, $Res Function(_StructuredLyrics) _then) = __$StructuredLyricsCopyWithImpl;
@override @useResult
$Res call({
 String? lang, bool? synced, List<LyricLine> line
});




}
/// @nodoc
class __$StructuredLyricsCopyWithImpl<$Res>
    implements _$StructuredLyricsCopyWith<$Res> {
  __$StructuredLyricsCopyWithImpl(this._self, this._then);

  final _StructuredLyrics _self;
  final $Res Function(_StructuredLyrics) _then;

/// Create a copy of StructuredLyrics
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? lang = freezed,Object? synced = freezed,Object? line = null,}) {
  return _then(_StructuredLyrics(
lang: freezed == lang ? _self.lang : lang // ignore: cast_nullable_to_non_nullable
as String?,synced: freezed == synced ? _self.synced : synced // ignore: cast_nullable_to_non_nullable
as bool?,line: null == line ? _self._line : line // ignore: cast_nullable_to_non_nullable
as List<LyricLine>,
  ));
}


}


/// @nodoc
mixin _$LyricsList {

 List<StructuredLyrics> get structuredLyrics; String? get value;
/// Create a copy of LyricsList
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$LyricsListCopyWith<LyricsList> get copyWith => _$LyricsListCopyWithImpl<LyricsList>(this as LyricsList, _$identity);

  /// Serializes this LyricsList to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is LyricsList&&const DeepCollectionEquality().equals(other.structuredLyrics, structuredLyrics)&&(identical(other.value, value) || other.value == value));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(structuredLyrics),value);

@override
String toString() {
  return 'LyricsList(structuredLyrics: $structuredLyrics, value: $value)';
}


}

/// @nodoc
abstract mixin class $LyricsListCopyWith<$Res>  {
  factory $LyricsListCopyWith(LyricsList value, $Res Function(LyricsList) _then) = _$LyricsListCopyWithImpl;
@useResult
$Res call({
 List<StructuredLyrics> structuredLyrics, String? value
});




}
/// @nodoc
class _$LyricsListCopyWithImpl<$Res>
    implements $LyricsListCopyWith<$Res> {
  _$LyricsListCopyWithImpl(this._self, this._then);

  final LyricsList _self;
  final $Res Function(LyricsList) _then;

/// Create a copy of LyricsList
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? structuredLyrics = null,Object? value = freezed,}) {
  return _then(_self.copyWith(
structuredLyrics: null == structuredLyrics ? _self.structuredLyrics : structuredLyrics // ignore: cast_nullable_to_non_nullable
as List<StructuredLyrics>,value: freezed == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [LyricsList].
extension LyricsListPatterns on LyricsList {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _LyricsList value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _LyricsList() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _LyricsList value)  $default,){
final _that = this;
switch (_that) {
case _LyricsList():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _LyricsList value)?  $default,){
final _that = this;
switch (_that) {
case _LyricsList() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( List<StructuredLyrics> structuredLyrics,  String? value)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _LyricsList() when $default != null:
return $default(_that.structuredLyrics,_that.value);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( List<StructuredLyrics> structuredLyrics,  String? value)  $default,) {final _that = this;
switch (_that) {
case _LyricsList():
return $default(_that.structuredLyrics,_that.value);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( List<StructuredLyrics> structuredLyrics,  String? value)?  $default,) {final _that = this;
switch (_that) {
case _LyricsList() when $default != null:
return $default(_that.structuredLyrics,_that.value);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _LyricsList implements LyricsList {
  const _LyricsList({final  List<StructuredLyrics> structuredLyrics = const <StructuredLyrics>[], this.value}): _structuredLyrics = structuredLyrics;
  factory _LyricsList.fromJson(Map<String, dynamic> json) => _$LyricsListFromJson(json);

 final  List<StructuredLyrics> _structuredLyrics;
@override@JsonKey() List<StructuredLyrics> get structuredLyrics {
  if (_structuredLyrics is EqualUnmodifiableListView) return _structuredLyrics;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_structuredLyrics);
}

@override final  String? value;

/// Create a copy of LyricsList
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$LyricsListCopyWith<_LyricsList> get copyWith => __$LyricsListCopyWithImpl<_LyricsList>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$LyricsListToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _LyricsList&&const DeepCollectionEquality().equals(other._structuredLyrics, _structuredLyrics)&&(identical(other.value, value) || other.value == value));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_structuredLyrics),value);

@override
String toString() {
  return 'LyricsList(structuredLyrics: $structuredLyrics, value: $value)';
}


}

/// @nodoc
abstract mixin class _$LyricsListCopyWith<$Res> implements $LyricsListCopyWith<$Res> {
  factory _$LyricsListCopyWith(_LyricsList value, $Res Function(_LyricsList) _then) = __$LyricsListCopyWithImpl;
@override @useResult
$Res call({
 List<StructuredLyrics> structuredLyrics, String? value
});




}
/// @nodoc
class __$LyricsListCopyWithImpl<$Res>
    implements _$LyricsListCopyWith<$Res> {
  __$LyricsListCopyWithImpl(this._self, this._then);

  final _LyricsList _self;
  final $Res Function(_LyricsList) _then;

/// Create a copy of LyricsList
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? structuredLyrics = null,Object? value = freezed,}) {
  return _then(_LyricsList(
structuredLyrics: null == structuredLyrics ? _self._structuredLyrics : structuredLyrics // ignore: cast_nullable_to_non_nullable
as List<StructuredLyrics>,value: freezed == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
