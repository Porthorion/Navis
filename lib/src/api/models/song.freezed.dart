// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'song.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Song {

 String get id; String get title; String? get album; String? get albumId; String? get artist; String? get artistId; int? get track; int? get discNumber; int? get year; int? get duration; int? get bitRate; String? get contentType; String? get suffix; int? get size; String? get coverArt; DateTime? get starred; int? get playCount; DateTime? get created; ReplayGain? get replayGain;
/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SongCopyWith<Song> get copyWith => _$SongCopyWithImpl<Song>(this as Song, _$identity);

  /// Serializes this Song to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Song&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.album, album) || other.album == album)&&(identical(other.albumId, albumId) || other.albumId == albumId)&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.artistId, artistId) || other.artistId == artistId)&&(identical(other.track, track) || other.track == track)&&(identical(other.discNumber, discNumber) || other.discNumber == discNumber)&&(identical(other.year, year) || other.year == year)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.bitRate, bitRate) || other.bitRate == bitRate)&&(identical(other.contentType, contentType) || other.contentType == contentType)&&(identical(other.suffix, suffix) || other.suffix == suffix)&&(identical(other.size, size) || other.size == size)&&(identical(other.coverArt, coverArt) || other.coverArt == coverArt)&&(identical(other.starred, starred) || other.starred == starred)&&(identical(other.playCount, playCount) || other.playCount == playCount)&&(identical(other.created, created) || other.created == created)&&(identical(other.replayGain, replayGain) || other.replayGain == replayGain));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,title,album,albumId,artist,artistId,track,discNumber,year,duration,bitRate,contentType,suffix,size,coverArt,starred,playCount,created,replayGain]);

@override
String toString() {
  return 'Song(id: $id, title: $title, album: $album, albumId: $albumId, artist: $artist, artistId: $artistId, track: $track, discNumber: $discNumber, year: $year, duration: $duration, bitRate: $bitRate, contentType: $contentType, suffix: $suffix, size: $size, coverArt: $coverArt, starred: $starred, playCount: $playCount, created: $created, replayGain: $replayGain)';
}


}

/// @nodoc
abstract mixin class $SongCopyWith<$Res>  {
  factory $SongCopyWith(Song value, $Res Function(Song) _then) = _$SongCopyWithImpl;
@useResult
$Res call({
 String id, String title, String? album, String? albumId, String? artist, String? artistId, int? track, int? discNumber, int? year, int? duration, int? bitRate, String? contentType, String? suffix, int? size, String? coverArt, DateTime? starred, int? playCount, DateTime? created, ReplayGain? replayGain
});


$ReplayGainCopyWith<$Res>? get replayGain;

}
/// @nodoc
class _$SongCopyWithImpl<$Res>
    implements $SongCopyWith<$Res> {
  _$SongCopyWithImpl(this._self, this._then);

  final Song _self;
  final $Res Function(Song) _then;

/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? title = null,Object? album = freezed,Object? albumId = freezed,Object? artist = freezed,Object? artistId = freezed,Object? track = freezed,Object? discNumber = freezed,Object? year = freezed,Object? duration = freezed,Object? bitRate = freezed,Object? contentType = freezed,Object? suffix = freezed,Object? size = freezed,Object? coverArt = freezed,Object? starred = freezed,Object? playCount = freezed,Object? created = freezed,Object? replayGain = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,album: freezed == album ? _self.album : album // ignore: cast_nullable_to_non_nullable
as String?,albumId: freezed == albumId ? _self.albumId : albumId // ignore: cast_nullable_to_non_nullable
as String?,artist: freezed == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String?,artistId: freezed == artistId ? _self.artistId : artistId // ignore: cast_nullable_to_non_nullable
as String?,track: freezed == track ? _self.track : track // ignore: cast_nullable_to_non_nullable
as int?,discNumber: freezed == discNumber ? _self.discNumber : discNumber // ignore: cast_nullable_to_non_nullable
as int?,year: freezed == year ? _self.year : year // ignore: cast_nullable_to_non_nullable
as int?,duration: freezed == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as int?,bitRate: freezed == bitRate ? _self.bitRate : bitRate // ignore: cast_nullable_to_non_nullable
as int?,contentType: freezed == contentType ? _self.contentType : contentType // ignore: cast_nullable_to_non_nullable
as String?,suffix: freezed == suffix ? _self.suffix : suffix // ignore: cast_nullable_to_non_nullable
as String?,size: freezed == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as int?,coverArt: freezed == coverArt ? _self.coverArt : coverArt // ignore: cast_nullable_to_non_nullable
as String?,starred: freezed == starred ? _self.starred : starred // ignore: cast_nullable_to_non_nullable
as DateTime?,playCount: freezed == playCount ? _self.playCount : playCount // ignore: cast_nullable_to_non_nullable
as int?,created: freezed == created ? _self.created : created // ignore: cast_nullable_to_non_nullable
as DateTime?,replayGain: freezed == replayGain ? _self.replayGain : replayGain // ignore: cast_nullable_to_non_nullable
as ReplayGain?,
  ));
}
/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ReplayGainCopyWith<$Res>? get replayGain {
    if (_self.replayGain == null) {
    return null;
  }

  return $ReplayGainCopyWith<$Res>(_self.replayGain!, (value) {
    return _then(_self.copyWith(replayGain: value));
  });
}
}


/// Adds pattern-matching-related methods to [Song].
extension SongPatterns on Song {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Song value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Song() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Song value)  $default,){
final _that = this;
switch (_that) {
case _Song():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Song value)?  $default,){
final _that = this;
switch (_that) {
case _Song() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String title,  String? album,  String? albumId,  String? artist,  String? artistId,  int? track,  int? discNumber,  int? year,  int? duration,  int? bitRate,  String? contentType,  String? suffix,  int? size,  String? coverArt,  DateTime? starred,  int? playCount,  DateTime? created,  ReplayGain? replayGain)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Song() when $default != null:
return $default(_that.id,_that.title,_that.album,_that.albumId,_that.artist,_that.artistId,_that.track,_that.discNumber,_that.year,_that.duration,_that.bitRate,_that.contentType,_that.suffix,_that.size,_that.coverArt,_that.starred,_that.playCount,_that.created,_that.replayGain);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String title,  String? album,  String? albumId,  String? artist,  String? artistId,  int? track,  int? discNumber,  int? year,  int? duration,  int? bitRate,  String? contentType,  String? suffix,  int? size,  String? coverArt,  DateTime? starred,  int? playCount,  DateTime? created,  ReplayGain? replayGain)  $default,) {final _that = this;
switch (_that) {
case _Song():
return $default(_that.id,_that.title,_that.album,_that.albumId,_that.artist,_that.artistId,_that.track,_that.discNumber,_that.year,_that.duration,_that.bitRate,_that.contentType,_that.suffix,_that.size,_that.coverArt,_that.starred,_that.playCount,_that.created,_that.replayGain);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String title,  String? album,  String? albumId,  String? artist,  String? artistId,  int? track,  int? discNumber,  int? year,  int? duration,  int? bitRate,  String? contentType,  String? suffix,  int? size,  String? coverArt,  DateTime? starred,  int? playCount,  DateTime? created,  ReplayGain? replayGain)?  $default,) {final _that = this;
switch (_that) {
case _Song() when $default != null:
return $default(_that.id,_that.title,_that.album,_that.albumId,_that.artist,_that.artistId,_that.track,_that.discNumber,_that.year,_that.duration,_that.bitRate,_that.contentType,_that.suffix,_that.size,_that.coverArt,_that.starred,_that.playCount,_that.created,_that.replayGain);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(explicitToJson: true)
class _Song implements Song {
  const _Song({required this.id, required this.title, this.album, this.albumId, this.artist, this.artistId, this.track, this.discNumber, this.year, this.duration, this.bitRate, this.contentType, this.suffix, this.size, this.coverArt, this.starred, this.playCount, this.created, this.replayGain});
  factory _Song.fromJson(Map<String, dynamic> json) => _$SongFromJson(json);

@override final  String id;
@override final  String title;
@override final  String? album;
@override final  String? albumId;
@override final  String? artist;
@override final  String? artistId;
@override final  int? track;
@override final  int? discNumber;
@override final  int? year;
@override final  int? duration;
@override final  int? bitRate;
@override final  String? contentType;
@override final  String? suffix;
@override final  int? size;
@override final  String? coverArt;
@override final  DateTime? starred;
@override final  int? playCount;
@override final  DateTime? created;
@override final  ReplayGain? replayGain;

/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SongCopyWith<_Song> get copyWith => __$SongCopyWithImpl<_Song>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SongToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Song&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.album, album) || other.album == album)&&(identical(other.albumId, albumId) || other.albumId == albumId)&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.artistId, artistId) || other.artistId == artistId)&&(identical(other.track, track) || other.track == track)&&(identical(other.discNumber, discNumber) || other.discNumber == discNumber)&&(identical(other.year, year) || other.year == year)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.bitRate, bitRate) || other.bitRate == bitRate)&&(identical(other.contentType, contentType) || other.contentType == contentType)&&(identical(other.suffix, suffix) || other.suffix == suffix)&&(identical(other.size, size) || other.size == size)&&(identical(other.coverArt, coverArt) || other.coverArt == coverArt)&&(identical(other.starred, starred) || other.starred == starred)&&(identical(other.playCount, playCount) || other.playCount == playCount)&&(identical(other.created, created) || other.created == created)&&(identical(other.replayGain, replayGain) || other.replayGain == replayGain));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,title,album,albumId,artist,artistId,track,discNumber,year,duration,bitRate,contentType,suffix,size,coverArt,starred,playCount,created,replayGain]);

@override
String toString() {
  return 'Song(id: $id, title: $title, album: $album, albumId: $albumId, artist: $artist, artistId: $artistId, track: $track, discNumber: $discNumber, year: $year, duration: $duration, bitRate: $bitRate, contentType: $contentType, suffix: $suffix, size: $size, coverArt: $coverArt, starred: $starred, playCount: $playCount, created: $created, replayGain: $replayGain)';
}


}

/// @nodoc
abstract mixin class _$SongCopyWith<$Res> implements $SongCopyWith<$Res> {
  factory _$SongCopyWith(_Song value, $Res Function(_Song) _then) = __$SongCopyWithImpl;
@override @useResult
$Res call({
 String id, String title, String? album, String? albumId, String? artist, String? artistId, int? track, int? discNumber, int? year, int? duration, int? bitRate, String? contentType, String? suffix, int? size, String? coverArt, DateTime? starred, int? playCount, DateTime? created, ReplayGain? replayGain
});


@override $ReplayGainCopyWith<$Res>? get replayGain;

}
/// @nodoc
class __$SongCopyWithImpl<$Res>
    implements _$SongCopyWith<$Res> {
  __$SongCopyWithImpl(this._self, this._then);

  final _Song _self;
  final $Res Function(_Song) _then;

/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? title = null,Object? album = freezed,Object? albumId = freezed,Object? artist = freezed,Object? artistId = freezed,Object? track = freezed,Object? discNumber = freezed,Object? year = freezed,Object? duration = freezed,Object? bitRate = freezed,Object? contentType = freezed,Object? suffix = freezed,Object? size = freezed,Object? coverArt = freezed,Object? starred = freezed,Object? playCount = freezed,Object? created = freezed,Object? replayGain = freezed,}) {
  return _then(_Song(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,album: freezed == album ? _self.album : album // ignore: cast_nullable_to_non_nullable
as String?,albumId: freezed == albumId ? _self.albumId : albumId // ignore: cast_nullable_to_non_nullable
as String?,artist: freezed == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String?,artistId: freezed == artistId ? _self.artistId : artistId // ignore: cast_nullable_to_non_nullable
as String?,track: freezed == track ? _self.track : track // ignore: cast_nullable_to_non_nullable
as int?,discNumber: freezed == discNumber ? _self.discNumber : discNumber // ignore: cast_nullable_to_non_nullable
as int?,year: freezed == year ? _self.year : year // ignore: cast_nullable_to_non_nullable
as int?,duration: freezed == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as int?,bitRate: freezed == bitRate ? _self.bitRate : bitRate // ignore: cast_nullable_to_non_nullable
as int?,contentType: freezed == contentType ? _self.contentType : contentType // ignore: cast_nullable_to_non_nullable
as String?,suffix: freezed == suffix ? _self.suffix : suffix // ignore: cast_nullable_to_non_nullable
as String?,size: freezed == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as int?,coverArt: freezed == coverArt ? _self.coverArt : coverArt // ignore: cast_nullable_to_non_nullable
as String?,starred: freezed == starred ? _self.starred : starred // ignore: cast_nullable_to_non_nullable
as DateTime?,playCount: freezed == playCount ? _self.playCount : playCount // ignore: cast_nullable_to_non_nullable
as int?,created: freezed == created ? _self.created : created // ignore: cast_nullable_to_non_nullable
as DateTime?,replayGain: freezed == replayGain ? _self.replayGain : replayGain // ignore: cast_nullable_to_non_nullable
as ReplayGain?,
  ));
}

/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ReplayGainCopyWith<$Res>? get replayGain {
    if (_self.replayGain == null) {
    return null;
  }

  return $ReplayGainCopyWith<$Res>(_self.replayGain!, (value) {
    return _then(_self.copyWith(replayGain: value));
  });
}
}


/// @nodoc
mixin _$ReplayGain {

 double? get trackGain; double? get albumGain; double? get trackPeak; double? get albumPeak;
/// Create a copy of ReplayGain
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ReplayGainCopyWith<ReplayGain> get copyWith => _$ReplayGainCopyWithImpl<ReplayGain>(this as ReplayGain, _$identity);

  /// Serializes this ReplayGain to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ReplayGain&&(identical(other.trackGain, trackGain) || other.trackGain == trackGain)&&(identical(other.albumGain, albumGain) || other.albumGain == albumGain)&&(identical(other.trackPeak, trackPeak) || other.trackPeak == trackPeak)&&(identical(other.albumPeak, albumPeak) || other.albumPeak == albumPeak));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,trackGain,albumGain,trackPeak,albumPeak);

@override
String toString() {
  return 'ReplayGain(trackGain: $trackGain, albumGain: $albumGain, trackPeak: $trackPeak, albumPeak: $albumPeak)';
}


}

/// @nodoc
abstract mixin class $ReplayGainCopyWith<$Res>  {
  factory $ReplayGainCopyWith(ReplayGain value, $Res Function(ReplayGain) _then) = _$ReplayGainCopyWithImpl;
@useResult
$Res call({
 double? trackGain, double? albumGain, double? trackPeak, double? albumPeak
});




}
/// @nodoc
class _$ReplayGainCopyWithImpl<$Res>
    implements $ReplayGainCopyWith<$Res> {
  _$ReplayGainCopyWithImpl(this._self, this._then);

  final ReplayGain _self;
  final $Res Function(ReplayGain) _then;

/// Create a copy of ReplayGain
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? trackGain = freezed,Object? albumGain = freezed,Object? trackPeak = freezed,Object? albumPeak = freezed,}) {
  return _then(_self.copyWith(
trackGain: freezed == trackGain ? _self.trackGain : trackGain // ignore: cast_nullable_to_non_nullable
as double?,albumGain: freezed == albumGain ? _self.albumGain : albumGain // ignore: cast_nullable_to_non_nullable
as double?,trackPeak: freezed == trackPeak ? _self.trackPeak : trackPeak // ignore: cast_nullable_to_non_nullable
as double?,albumPeak: freezed == albumPeak ? _self.albumPeak : albumPeak // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}

}


/// Adds pattern-matching-related methods to [ReplayGain].
extension ReplayGainPatterns on ReplayGain {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ReplayGain value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ReplayGain() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ReplayGain value)  $default,){
final _that = this;
switch (_that) {
case _ReplayGain():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ReplayGain value)?  $default,){
final _that = this;
switch (_that) {
case _ReplayGain() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double? trackGain,  double? albumGain,  double? trackPeak,  double? albumPeak)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ReplayGain() when $default != null:
return $default(_that.trackGain,_that.albumGain,_that.trackPeak,_that.albumPeak);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double? trackGain,  double? albumGain,  double? trackPeak,  double? albumPeak)  $default,) {final _that = this;
switch (_that) {
case _ReplayGain():
return $default(_that.trackGain,_that.albumGain,_that.trackPeak,_that.albumPeak);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double? trackGain,  double? albumGain,  double? trackPeak,  double? albumPeak)?  $default,) {final _that = this;
switch (_that) {
case _ReplayGain() when $default != null:
return $default(_that.trackGain,_that.albumGain,_that.trackPeak,_that.albumPeak);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ReplayGain implements ReplayGain {
  const _ReplayGain({this.trackGain, this.albumGain, this.trackPeak, this.albumPeak});
  factory _ReplayGain.fromJson(Map<String, dynamic> json) => _$ReplayGainFromJson(json);

@override final  double? trackGain;
@override final  double? albumGain;
@override final  double? trackPeak;
@override final  double? albumPeak;

/// Create a copy of ReplayGain
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ReplayGainCopyWith<_ReplayGain> get copyWith => __$ReplayGainCopyWithImpl<_ReplayGain>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ReplayGainToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ReplayGain&&(identical(other.trackGain, trackGain) || other.trackGain == trackGain)&&(identical(other.albumGain, albumGain) || other.albumGain == albumGain)&&(identical(other.trackPeak, trackPeak) || other.trackPeak == trackPeak)&&(identical(other.albumPeak, albumPeak) || other.albumPeak == albumPeak));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,trackGain,albumGain,trackPeak,albumPeak);

@override
String toString() {
  return 'ReplayGain(trackGain: $trackGain, albumGain: $albumGain, trackPeak: $trackPeak, albumPeak: $albumPeak)';
}


}

/// @nodoc
abstract mixin class _$ReplayGainCopyWith<$Res> implements $ReplayGainCopyWith<$Res> {
  factory _$ReplayGainCopyWith(_ReplayGain value, $Res Function(_ReplayGain) _then) = __$ReplayGainCopyWithImpl;
@override @useResult
$Res call({
 double? trackGain, double? albumGain, double? trackPeak, double? albumPeak
});




}
/// @nodoc
class __$ReplayGainCopyWithImpl<$Res>
    implements _$ReplayGainCopyWith<$Res> {
  __$ReplayGainCopyWithImpl(this._self, this._then);

  final _ReplayGain _self;
  final $Res Function(_ReplayGain) _then;

/// Create a copy of ReplayGain
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? trackGain = freezed,Object? albumGain = freezed,Object? trackPeak = freezed,Object? albumPeak = freezed,}) {
  return _then(_ReplayGain(
trackGain: freezed == trackGain ? _self.trackGain : trackGain // ignore: cast_nullable_to_non_nullable
as double?,albumGain: freezed == albumGain ? _self.albumGain : albumGain // ignore: cast_nullable_to_non_nullable
as double?,trackPeak: freezed == trackPeak ? _self.trackPeak : trackPeak // ignore: cast_nullable_to_non_nullable
as double?,albumPeak: freezed == albumPeak ? _self.albumPeak : albumPeak // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}


}

// dart format on
