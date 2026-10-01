// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'song.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Song {

 String get id; String get title; String? get album; String? get albumId; String? get artist; String? get artistId; int? get track; int? get discNumber; int? get year; int? get duration; int? get bitRate;@JsonKey(readValue: _readSampleRateJson) int? get sampleRate; String? get contentType; String? get suffix; int? get size; String? get coverArt; DateTime? get starred; String? get musicBrainzId; int? get userRating; int? get playCount; DateTime? get created; bool? get isExternal; ReplayGain? get replayGain;
/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SongCopyWith<Song> get copyWith => _$SongCopyWithImpl<Song>(this as Song, _$identity);

  /// Serializes this Song to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as Song;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Song&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.title, _this.title) || other.title == _this.title)&&(identical(other.album, _this.album) || other.album == _this.album)&&(identical(other.albumId, _this.albumId) || other.albumId == _this.albumId)&&(identical(other.artist, _this.artist) || other.artist == _this.artist)&&(identical(other.artistId, _this.artistId) || other.artistId == _this.artistId)&&(identical(other.track, _this.track) || other.track == _this.track)&&(identical(other.discNumber, _this.discNumber) || other.discNumber == _this.discNumber)&&(identical(other.year, _this.year) || other.year == _this.year)&&(identical(other.duration, _this.duration) || other.duration == _this.duration)&&(identical(other.bitRate, _this.bitRate) || other.bitRate == _this.bitRate)&&(identical(other.sampleRate, _this.sampleRate) || other.sampleRate == _this.sampleRate)&&(identical(other.contentType, _this.contentType) || other.contentType == _this.contentType)&&(identical(other.suffix, _this.suffix) || other.suffix == _this.suffix)&&(identical(other.size, _this.size) || other.size == _this.size)&&(identical(other.coverArt, _this.coverArt) || other.coverArt == _this.coverArt)&&(identical(other.starred, _this.starred) || other.starred == _this.starred)&&(identical(other.musicBrainzId, _this.musicBrainzId) || other.musicBrainzId == _this.musicBrainzId)&&(identical(other.userRating, _this.userRating) || other.userRating == _this.userRating)&&(identical(other.playCount, _this.playCount) || other.playCount == _this.playCount)&&(identical(other.created, _this.created) || other.created == _this.created)&&(identical(other.isExternal, _this.isExternal) || other.isExternal == _this.isExternal)&&(identical(other.replayGain, _this.replayGain) || other.replayGain == _this.replayGain));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as Song;
  return Object.hashAll([runtimeType,_this.id,_this.title,_this.album,_this.albumId,_this.artist,_this.artistId,_this.track,_this.discNumber,_this.year,_this.duration,_this.bitRate,_this.sampleRate,_this.contentType,_this.suffix,_this.size,_this.coverArt,_this.starred,_this.musicBrainzId,_this.userRating,_this.playCount,_this.created,_this.isExternal,_this.replayGain]);
}

@override
String toString() {
  final _this = this as Song;
  return 'Song(id: ${_this.id}, title: ${_this.title}, album: ${_this.album}, albumId: ${_this.albumId}, artist: ${_this.artist}, artistId: ${_this.artistId}, track: ${_this.track}, discNumber: ${_this.discNumber}, year: ${_this.year}, duration: ${_this.duration}, bitRate: ${_this.bitRate}, sampleRate: ${_this.sampleRate}, contentType: ${_this.contentType}, suffix: ${_this.suffix}, size: ${_this.size}, coverArt: ${_this.coverArt}, starred: ${_this.starred}, musicBrainzId: ${_this.musicBrainzId}, userRating: ${_this.userRating}, playCount: ${_this.playCount}, created: ${_this.created}, isExternal: ${_this.isExternal}, replayGain: ${_this.replayGain})';
}


}

/// @nodoc
abstract mixin class $SongCopyWith<$Res>  {
  factory $SongCopyWith(Song value, $Res Function(Song) _then) = _$SongCopyWithImpl;
@useResult
$Res call({
 String id, String title, String? album, String? albumId, String? artist, String? artistId, int? track, int? discNumber, int? year, int? duration, int? bitRate,@JsonKey(readValue: _readSampleRateJson) int? sampleRate, String? contentType, String? suffix, int? size, String? coverArt, DateTime? starred, String? musicBrainzId, int? userRating, int? playCount, DateTime? created, bool? isExternal, ReplayGain? replayGain
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
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? title = null,Object? album = freezed,Object? albumId = freezed,Object? artist = freezed,Object? artistId = freezed,Object? track = freezed,Object? discNumber = freezed,Object? year = freezed,Object? duration = freezed,Object? bitRate = freezed,Object? sampleRate = freezed,Object? contentType = freezed,Object? suffix = freezed,Object? size = freezed,Object? coverArt = freezed,Object? starred = freezed,Object? musicBrainzId = freezed,Object? userRating = freezed,Object? playCount = freezed,Object? created = freezed,Object? isExternal = freezed,Object? replayGain = freezed,}) {
  return _then(Song(
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
as int?,sampleRate: freezed == sampleRate ? _self.sampleRate : sampleRate // ignore: cast_nullable_to_non_nullable
as int?,contentType: freezed == contentType ? _self.contentType : contentType // ignore: cast_nullable_to_non_nullable
as String?,suffix: freezed == suffix ? _self.suffix : suffix // ignore: cast_nullable_to_non_nullable
as String?,size: freezed == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as int?,coverArt: freezed == coverArt ? _self.coverArt : coverArt // ignore: cast_nullable_to_non_nullable
as String?,starred: freezed == starred ? _self.starred : starred // ignore: cast_nullable_to_non_nullable
as DateTime?,musicBrainzId: freezed == musicBrainzId ? _self.musicBrainzId : musicBrainzId // ignore: cast_nullable_to_non_nullable
as String?,userRating: freezed == userRating ? _self.userRating : userRating // ignore: cast_nullable_to_non_nullable
as int?,playCount: freezed == playCount ? _self.playCount : playCount // ignore: cast_nullable_to_non_nullable
as int?,created: freezed == created ? _self.created : created // ignore: cast_nullable_to_non_nullable
as DateTime?,isExternal: freezed == isExternal ? _self.isExternal : isExternal // ignore: cast_nullable_to_non_nullable
as bool?,replayGain: freezed == replayGain ? _self.replayGain : replayGain // ignore: cast_nullable_to_non_nullable
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String title,  String? album,  String? albumId,  String? artist,  String? artistId,  int? track,  int? discNumber,  int? year,  int? duration,  int? bitRate, @JsonKey(readValue: _readSampleRateJson)  int? sampleRate,  String? contentType,  String? suffix,  int? size,  String? coverArt,  DateTime? starred,  String? musicBrainzId,  int? userRating,  int? playCount,  DateTime? created,  bool? isExternal,  ReplayGain? replayGain)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Song() when $default != null:
return $default(_that.id,_that.title,_that.album,_that.albumId,_that.artist,_that.artistId,_that.track,_that.discNumber,_that.year,_that.duration,_that.bitRate,_that.sampleRate,_that.contentType,_that.suffix,_that.size,_that.coverArt,_that.starred,_that.musicBrainzId,_that.userRating,_that.playCount,_that.created,_that.isExternal,_that.replayGain);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String title,  String? album,  String? albumId,  String? artist,  String? artistId,  int? track,  int? discNumber,  int? year,  int? duration,  int? bitRate, @JsonKey(readValue: _readSampleRateJson)  int? sampleRate,  String? contentType,  String? suffix,  int? size,  String? coverArt,  DateTime? starred,  String? musicBrainzId,  int? userRating,  int? playCount,  DateTime? created,  bool? isExternal,  ReplayGain? replayGain)  $default,) {final _that = this;
switch (_that) {
case _Song():
return $default(_that.id,_that.title,_that.album,_that.albumId,_that.artist,_that.artistId,_that.track,_that.discNumber,_that.year,_that.duration,_that.bitRate,_that.sampleRate,_that.contentType,_that.suffix,_that.size,_that.coverArt,_that.starred,_that.musicBrainzId,_that.userRating,_that.playCount,_that.created,_that.isExternal,_that.replayGain);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String title,  String? album,  String? albumId,  String? artist,  String? artistId,  int? track,  int? discNumber,  int? year,  int? duration,  int? bitRate, @JsonKey(readValue: _readSampleRateJson)  int? sampleRate,  String? contentType,  String? suffix,  int? size,  String? coverArt,  DateTime? starred,  String? musicBrainzId,  int? userRating,  int? playCount,  DateTime? created,  bool? isExternal,  ReplayGain? replayGain)?  $default,) {final _that = this;
switch (_that) {
case _Song() when $default != null:
return $default(_that.id,_that.title,_that.album,_that.albumId,_that.artist,_that.artistId,_that.track,_that.discNumber,_that.year,_that.duration,_that.bitRate,_that.sampleRate,_that.contentType,_that.suffix,_that.size,_that.coverArt,_that.starred,_that.musicBrainzId,_that.userRating,_that.playCount,_that.created,_that.isExternal,_that.replayGain);case _:
  return null;

}
}

}

/// @nodoc

@JsonSerializable(explicitToJson: true)
class _Song implements Song {
  const _Song({required this.id, required this.title, this.album, this.albumId, this.artist, this.artistId, this.track, this.discNumber, this.year, this.duration, this.bitRate, @JsonKey(readValue: _readSampleRateJson) this.sampleRate, this.contentType, this.suffix, this.size, this.coverArt, this.starred, this.musicBrainzId, this.userRating, this.playCount, this.created, this.isExternal, this.replayGain});
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
@override@JsonKey(readValue: _readSampleRateJson) final  int? sampleRate;
@override final  String? contentType;
@override final  String? suffix;
@override final  int? size;
@override final  String? coverArt;
@override final  DateTime? starred;
@override final  String? musicBrainzId;
@override final  int? userRating;
@override final  int? playCount;
@override final  DateTime? created;
@override final  bool? isExternal;
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
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _Song&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.album, album) || other.album == album)&&(identical(other.albumId, albumId) || other.albumId == albumId)&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.artistId, artistId) || other.artistId == artistId)&&(identical(other.track, track) || other.track == track)&&(identical(other.discNumber, discNumber) || other.discNumber == discNumber)&&(identical(other.year, year) || other.year == year)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.bitRate, bitRate) || other.bitRate == bitRate)&&(identical(other.sampleRate, sampleRate) || other.sampleRate == sampleRate)&&(identical(other.contentType, contentType) || other.contentType == contentType)&&(identical(other.suffix, suffix) || other.suffix == suffix)&&(identical(other.size, size) || other.size == size)&&(identical(other.coverArt, coverArt) || other.coverArt == coverArt)&&(identical(other.starred, starred) || other.starred == starred)&&(identical(other.musicBrainzId, musicBrainzId) || other.musicBrainzId == musicBrainzId)&&(identical(other.userRating, userRating) || other.userRating == userRating)&&(identical(other.playCount, playCount) || other.playCount == playCount)&&(identical(other.created, created) || other.created == created)&&(identical(other.isExternal, isExternal) || other.isExternal == isExternal)&&(identical(other.replayGain, replayGain) || other.replayGain == replayGain));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hashAll([runtimeType,id,title,album,albumId,artist,artistId,track,discNumber,year,duration,bitRate,sampleRate,contentType,suffix,size,coverArt,starred,musicBrainzId,userRating,playCount,created,isExternal,replayGain]);
}

@override
String toString() {
    return 'Song(id: $id, title: $title, album: $album, albumId: $albumId, artist: $artist, artistId: $artistId, track: $track, discNumber: $discNumber, year: $year, duration: $duration, bitRate: $bitRate, sampleRate: $sampleRate, contentType: $contentType, suffix: $suffix, size: $size, coverArt: $coverArt, starred: $starred, musicBrainzId: $musicBrainzId, userRating: $userRating, playCount: $playCount, created: $created, isExternal: $isExternal, replayGain: $replayGain)';
}


}

/// @nodoc
abstract mixin class _$SongCopyWith<$Res> implements $SongCopyWith<$Res> {
  factory _$SongCopyWith(_Song value, $Res Function(_Song) _then) = __$SongCopyWithImpl;
@override @useResult
$Res call({
 String id, String title, String? album, String? albumId, String? artist, String? artistId, int? track, int? discNumber, int? year, int? duration, int? bitRate,@JsonKey(readValue: _readSampleRateJson) int? sampleRate, String? contentType, String? suffix, int? size, String? coverArt, DateTime? starred, String? musicBrainzId, int? userRating, int? playCount, DateTime? created, bool? isExternal, ReplayGain? replayGain
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
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? title = null,Object? album = freezed,Object? albumId = freezed,Object? artist = freezed,Object? artistId = freezed,Object? track = freezed,Object? discNumber = freezed,Object? year = freezed,Object? duration = freezed,Object? bitRate = freezed,Object? sampleRate = freezed,Object? contentType = freezed,Object? suffix = freezed,Object? size = freezed,Object? coverArt = freezed,Object? starred = freezed,Object? musicBrainzId = freezed,Object? userRating = freezed,Object? playCount = freezed,Object? created = freezed,Object? isExternal = freezed,Object? replayGain = freezed,}) {
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
as int?,sampleRate: freezed == sampleRate ? _self.sampleRate : sampleRate // ignore: cast_nullable_to_non_nullable
as int?,contentType: freezed == contentType ? _self.contentType : contentType // ignore: cast_nullable_to_non_nullable
as String?,suffix: freezed == suffix ? _self.suffix : suffix // ignore: cast_nullable_to_non_nullable
as String?,size: freezed == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as int?,coverArt: freezed == coverArt ? _self.coverArt : coverArt // ignore: cast_nullable_to_non_nullable
as String?,starred: freezed == starred ? _self.starred : starred // ignore: cast_nullable_to_non_nullable
as DateTime?,musicBrainzId: freezed == musicBrainzId ? _self.musicBrainzId : musicBrainzId // ignore: cast_nullable_to_non_nullable
as String?,userRating: freezed == userRating ? _self.userRating : userRating // ignore: cast_nullable_to_non_nullable
as int?,playCount: freezed == playCount ? _self.playCount : playCount // ignore: cast_nullable_to_non_nullable
as int?,created: freezed == created ? _self.created : created // ignore: cast_nullable_to_non_nullable
as DateTime?,isExternal: freezed == isExternal ? _self.isExternal : isExternal // ignore: cast_nullable_to_non_nullable
as bool?,replayGain: freezed == replayGain ? _self.replayGain : replayGain // ignore: cast_nullable_to_non_nullable
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
  final _this = this as ReplayGain;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ReplayGain&&(identical(other.trackGain, _this.trackGain) || other.trackGain == _this.trackGain)&&(identical(other.albumGain, _this.albumGain) || other.albumGain == _this.albumGain)&&(identical(other.trackPeak, _this.trackPeak) || other.trackPeak == _this.trackPeak)&&(identical(other.albumPeak, _this.albumPeak) || other.albumPeak == _this.albumPeak));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as ReplayGain;
  return Object.hash(runtimeType,_this.trackGain,_this.albumGain,_this.trackPeak,_this.albumPeak);
}

@override
String toString() {
  final _this = this as ReplayGain;
  return 'ReplayGain(trackGain: ${_this.trackGain}, albumGain: ${_this.albumGain}, trackPeak: ${_this.trackPeak}, albumPeak: ${_this.albumPeak})';
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
  return _then(ReplayGain(
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
int get hashCode {
    return Object.hash(runtimeType,trackGain,albumGain,trackPeak,albumPeak);
}

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
