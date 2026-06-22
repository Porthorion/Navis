import 'package:flutter/foundation.dart';

enum GroupListeningTrackRefKind { libraryId, searchFingerprint, mbid }

enum GroupListeningTrackRefSource {
  navidrome,
  octoFiesta,
  search3Remote,
}

enum GroupListeningPlayability {
  serverAddressable,
  requiresResolution,
}

@immutable
class GroupListeningSearchFingerprint {
  const GroupListeningSearchFingerprint({
    required this.title,
    required this.artist,
    this.album,
    required this.durationSeconds,
  });

  final String title;
  final String artist;
  final String? album;
  final int durationSeconds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningSearchFingerprint &&
          runtimeType == other.runtimeType &&
          title == other.title &&
          artist == other.artist &&
          album == other.album &&
          durationSeconds == other.durationSeconds;

  @override
  int get hashCode => Object.hash(title, artist, album, durationSeconds);
}

@immutable
class GroupListeningTrackRef {
  const GroupListeningTrackRef({
    required this.kind,
    this.librarySongId,
    this.mbid,
    this.searchFingerprint,
    this.source,
  });

  final GroupListeningTrackRefKind kind;
  final String? librarySongId;
  final String? mbid;
  final GroupListeningSearchFingerprint? searchFingerprint;
  final GroupListeningTrackRefSource? source;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningTrackRef &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          librarySongId == other.librarySongId &&
          mbid == other.mbid &&
          searchFingerprint == other.searchFingerprint &&
          source == other.source;

  @override
  int get hashCode =>
      Object.hash(kind, librarySongId, mbid, searchFingerprint, source);
}
