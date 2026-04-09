// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'share_content.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ShareContent {

 String? get coverArtId;
/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ShareContentCopyWith<ShareContent> get copyWith => _$ShareContentCopyWithImpl<ShareContent>(this as ShareContent, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ShareContent&&(identical(other.coverArtId, coverArtId) || other.coverArtId == coverArtId));
}


@override
int get hashCode => Object.hash(runtimeType,coverArtId);

@override
String toString() {
  return 'ShareContent(coverArtId: $coverArtId)';
}


}

/// @nodoc
abstract mixin class $ShareContentCopyWith<$Res>  {
  factory $ShareContentCopyWith(ShareContent value, $Res Function(ShareContent) _then) = _$ShareContentCopyWithImpl;
@useResult
$Res call({
 String? coverArtId
});




}
/// @nodoc
class _$ShareContentCopyWithImpl<$Res>
    implements $ShareContentCopyWith<$Res> {
  _$ShareContentCopyWithImpl(this._self, this._then);

  final ShareContent _self;
  final $Res Function(ShareContent) _then;

/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? coverArtId = freezed,}) {
  return _then(_self.copyWith(
coverArtId: freezed == coverArtId ? _self.coverArtId : coverArtId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ShareContent].
extension ShareContentPatterns on ShareContent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ShareSong value)?  song,TResult Function( ShareAlbum value)?  album,TResult Function( ShareArtist value)?  artist,TResult Function( SharePlaylist value)?  playlist,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ShareSong() when song != null:
return song(_that);case ShareAlbum() when album != null:
return album(_that);case ShareArtist() when artist != null:
return artist(_that);case SharePlaylist() when playlist != null:
return playlist(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ShareSong value)  song,required TResult Function( ShareAlbum value)  album,required TResult Function( ShareArtist value)  artist,required TResult Function( SharePlaylist value)  playlist,}){
final _that = this;
switch (_that) {
case ShareSong():
return song(_that);case ShareAlbum():
return album(_that);case ShareArtist():
return artist(_that);case SharePlaylist():
return playlist(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ShareSong value)?  song,TResult? Function( ShareAlbum value)?  album,TResult? Function( ShareArtist value)?  artist,TResult? Function( SharePlaylist value)?  playlist,}){
final _that = this;
switch (_that) {
case ShareSong() when song != null:
return song(_that);case ShareAlbum() when album != null:
return album(_that);case ShareArtist() when artist != null:
return artist(_that);case SharePlaylist() when playlist != null:
return playlist(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String title,  String artist,  String? album,  String? coverArtId)?  song,TResult Function( String name,  String artist,  String? coverArtId)?  album,TResult Function( String name,  String? coverArtId)?  artist,TResult Function( String name,  String? owner,  String? coverArtId)?  playlist,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ShareSong() when song != null:
return song(_that.title,_that.artist,_that.album,_that.coverArtId);case ShareAlbum() when album != null:
return album(_that.name,_that.artist,_that.coverArtId);case ShareArtist() when artist != null:
return artist(_that.name,_that.coverArtId);case SharePlaylist() when playlist != null:
return playlist(_that.name,_that.owner,_that.coverArtId);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String title,  String artist,  String? album,  String? coverArtId)  song,required TResult Function( String name,  String artist,  String? coverArtId)  album,required TResult Function( String name,  String? coverArtId)  artist,required TResult Function( String name,  String? owner,  String? coverArtId)  playlist,}) {final _that = this;
switch (_that) {
case ShareSong():
return song(_that.title,_that.artist,_that.album,_that.coverArtId);case ShareAlbum():
return album(_that.name,_that.artist,_that.coverArtId);case ShareArtist():
return artist(_that.name,_that.coverArtId);case SharePlaylist():
return playlist(_that.name,_that.owner,_that.coverArtId);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String title,  String artist,  String? album,  String? coverArtId)?  song,TResult? Function( String name,  String artist,  String? coverArtId)?  album,TResult? Function( String name,  String? coverArtId)?  artist,TResult? Function( String name,  String? owner,  String? coverArtId)?  playlist,}) {final _that = this;
switch (_that) {
case ShareSong() when song != null:
return song(_that.title,_that.artist,_that.album,_that.coverArtId);case ShareAlbum() when album != null:
return album(_that.name,_that.artist,_that.coverArtId);case ShareArtist() when artist != null:
return artist(_that.name,_that.coverArtId);case SharePlaylist() when playlist != null:
return playlist(_that.name,_that.owner,_that.coverArtId);case _:
  return null;

}
}

}

/// @nodoc


class ShareSong extends ShareContent {
  const ShareSong({required this.title, required this.artist, this.album, this.coverArtId}): super._();
  

 final  String title;
 final  String artist;
 final  String? album;
@override final  String? coverArtId;

/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ShareSongCopyWith<ShareSong> get copyWith => _$ShareSongCopyWithImpl<ShareSong>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ShareSong&&(identical(other.title, title) || other.title == title)&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.album, album) || other.album == album)&&(identical(other.coverArtId, coverArtId) || other.coverArtId == coverArtId));
}


@override
int get hashCode => Object.hash(runtimeType,title,artist,album,coverArtId);

@override
String toString() {
  return 'ShareContent.song(title: $title, artist: $artist, album: $album, coverArtId: $coverArtId)';
}


}

/// @nodoc
abstract mixin class $ShareSongCopyWith<$Res> implements $ShareContentCopyWith<$Res> {
  factory $ShareSongCopyWith(ShareSong value, $Res Function(ShareSong) _then) = _$ShareSongCopyWithImpl;
@override @useResult
$Res call({
 String title, String artist, String? album, String? coverArtId
});




}
/// @nodoc
class _$ShareSongCopyWithImpl<$Res>
    implements $ShareSongCopyWith<$Res> {
  _$ShareSongCopyWithImpl(this._self, this._then);

  final ShareSong _self;
  final $Res Function(ShareSong) _then;

/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? title = null,Object? artist = null,Object? album = freezed,Object? coverArtId = freezed,}) {
  return _then(ShareSong(
title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,artist: null == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String,album: freezed == album ? _self.album : album // ignore: cast_nullable_to_non_nullable
as String?,coverArtId: freezed == coverArtId ? _self.coverArtId : coverArtId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class ShareAlbum extends ShareContent {
  const ShareAlbum({required this.name, required this.artist, this.coverArtId}): super._();
  

 final  String name;
 final  String artist;
@override final  String? coverArtId;

/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ShareAlbumCopyWith<ShareAlbum> get copyWith => _$ShareAlbumCopyWithImpl<ShareAlbum>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ShareAlbum&&(identical(other.name, name) || other.name == name)&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.coverArtId, coverArtId) || other.coverArtId == coverArtId));
}


@override
int get hashCode => Object.hash(runtimeType,name,artist,coverArtId);

@override
String toString() {
  return 'ShareContent.album(name: $name, artist: $artist, coverArtId: $coverArtId)';
}


}

/// @nodoc
abstract mixin class $ShareAlbumCopyWith<$Res> implements $ShareContentCopyWith<$Res> {
  factory $ShareAlbumCopyWith(ShareAlbum value, $Res Function(ShareAlbum) _then) = _$ShareAlbumCopyWithImpl;
@override @useResult
$Res call({
 String name, String artist, String? coverArtId
});




}
/// @nodoc
class _$ShareAlbumCopyWithImpl<$Res>
    implements $ShareAlbumCopyWith<$Res> {
  _$ShareAlbumCopyWithImpl(this._self, this._then);

  final ShareAlbum _self;
  final $Res Function(ShareAlbum) _then;

/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? artist = null,Object? coverArtId = freezed,}) {
  return _then(ShareAlbum(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,artist: null == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String,coverArtId: freezed == coverArtId ? _self.coverArtId : coverArtId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class ShareArtist extends ShareContent {
  const ShareArtist({required this.name, this.coverArtId}): super._();
  

 final  String name;
@override final  String? coverArtId;

/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ShareArtistCopyWith<ShareArtist> get copyWith => _$ShareArtistCopyWithImpl<ShareArtist>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ShareArtist&&(identical(other.name, name) || other.name == name)&&(identical(other.coverArtId, coverArtId) || other.coverArtId == coverArtId));
}


@override
int get hashCode => Object.hash(runtimeType,name,coverArtId);

@override
String toString() {
  return 'ShareContent.artist(name: $name, coverArtId: $coverArtId)';
}


}

/// @nodoc
abstract mixin class $ShareArtistCopyWith<$Res> implements $ShareContentCopyWith<$Res> {
  factory $ShareArtistCopyWith(ShareArtist value, $Res Function(ShareArtist) _then) = _$ShareArtistCopyWithImpl;
@override @useResult
$Res call({
 String name, String? coverArtId
});




}
/// @nodoc
class _$ShareArtistCopyWithImpl<$Res>
    implements $ShareArtistCopyWith<$Res> {
  _$ShareArtistCopyWithImpl(this._self, this._then);

  final ShareArtist _self;
  final $Res Function(ShareArtist) _then;

/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? coverArtId = freezed,}) {
  return _then(ShareArtist(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,coverArtId: freezed == coverArtId ? _self.coverArtId : coverArtId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class SharePlaylist extends ShareContent {
  const SharePlaylist({required this.name, this.owner, this.coverArtId}): super._();
  

 final  String name;
 final  String? owner;
@override final  String? coverArtId;

/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SharePlaylistCopyWith<SharePlaylist> get copyWith => _$SharePlaylistCopyWithImpl<SharePlaylist>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SharePlaylist&&(identical(other.name, name) || other.name == name)&&(identical(other.owner, owner) || other.owner == owner)&&(identical(other.coverArtId, coverArtId) || other.coverArtId == coverArtId));
}


@override
int get hashCode => Object.hash(runtimeType,name,owner,coverArtId);

@override
String toString() {
  return 'ShareContent.playlist(name: $name, owner: $owner, coverArtId: $coverArtId)';
}


}

/// @nodoc
abstract mixin class $SharePlaylistCopyWith<$Res> implements $ShareContentCopyWith<$Res> {
  factory $SharePlaylistCopyWith(SharePlaylist value, $Res Function(SharePlaylist) _then) = _$SharePlaylistCopyWithImpl;
@override @useResult
$Res call({
 String name, String? owner, String? coverArtId
});




}
/// @nodoc
class _$SharePlaylistCopyWithImpl<$Res>
    implements $SharePlaylistCopyWith<$Res> {
  _$SharePlaylistCopyWithImpl(this._self, this._then);

  final SharePlaylist _self;
  final $Res Function(SharePlaylist) _then;

/// Create a copy of ShareContent
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? owner = freezed,Object? coverArtId = freezed,}) {
  return _then(SharePlaylist(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,owner: freezed == owner ? _self.owner : owner // ignore: cast_nullable_to_non_nullable
as String?,coverArtId: freezed == coverArtId ? _self.coverArtId : coverArtId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
