import 'package:flutter/foundation.dart';

import 'group_listening_track_ref_models.dart';

@immutable
class GroupListeningQueueEntry {
  const GroupListeningQueueEntry({
    required this.queueEntryId,
    required this.songId,
    this.addedByMemberId,
    required this.addedAt,
    this.title,
    this.artist,
    this.artistId,
    this.album,
    this.albumId,
    this.durationSeconds,
    this.track,
    this.discNumber,
    this.year,
    this.coverArt,
    this.contentType,
    this.suffix,
    this.bitRate,
    this.sampleRate,
    this.size,
    this.replayGainTrackGain,
    this.replayGainAlbumGain,
    this.replayGainTrackPeak,
    this.replayGainAlbumPeak,
    this.trackRef,
    this.playability = GroupListeningPlayability.serverAddressable,
  });

  final String queueEntryId;
  final String songId;
  final String? addedByMemberId;
  final DateTime addedAt;
  final String? title;
  final String? artist;
  final String? artistId;
  final String? album;
  final String? albumId;
  final int? durationSeconds;
  final int? track;
  final int? discNumber;
  final int? year;
  final String? coverArt;
  final String? contentType;
  final String? suffix;
  final int? bitRate;
  final int? sampleRate;
  final int? size;
  final double? replayGainTrackGain;
  final double? replayGainAlbumGain;
  final double? replayGainTrackPeak;
  final double? replayGainAlbumPeak;
  final GroupListeningTrackRef? trackRef;
  final GroupListeningPlayability playability;

  bool get hasMetadata =>
      title != null ||
      artist != null ||
      artistId != null ||
      album != null ||
      albumId != null ||
      durationSeconds != null ||
      track != null ||
      discNumber != null ||
      year != null ||
      coverArt != null ||
      contentType != null ||
      suffix != null ||
      bitRate != null ||
      sampleRate != null ||
      size != null ||
      replayGainTrackGain != null ||
      replayGainAlbumGain != null ||
      replayGainTrackPeak != null ||
      replayGainAlbumPeak != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningQueueEntry &&
          runtimeType == other.runtimeType &&
          queueEntryId == other.queueEntryId &&
          songId == other.songId &&
          addedByMemberId == other.addedByMemberId &&
          addedAt == other.addedAt &&
          title == other.title &&
          artist == other.artist &&
          artistId == other.artistId &&
          album == other.album &&
          albumId == other.albumId &&
          durationSeconds == other.durationSeconds &&
          track == other.track &&
          discNumber == other.discNumber &&
          year == other.year &&
          coverArt == other.coverArt &&
          contentType == other.contentType &&
          suffix == other.suffix &&
          bitRate == other.bitRate &&
          sampleRate == other.sampleRate &&
          size == other.size &&
          replayGainTrackGain == other.replayGainTrackGain &&
          replayGainAlbumGain == other.replayGainAlbumGain &&
          replayGainTrackPeak == other.replayGainTrackPeak &&
          replayGainAlbumPeak == other.replayGainAlbumPeak &&
          trackRef == other.trackRef &&
          playability == other.playability;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    queueEntryId,
    songId,
    addedByMemberId,
    addedAt,
    title,
    artist,
    artistId,
    album,
    albumId,
    durationSeconds,
    track,
    discNumber,
    year,
    coverArt,
    contentType,
    suffix,
    bitRate,
    sampleRate,
    size,
    replayGainTrackGain,
    replayGainAlbumGain,
    replayGainTrackPeak,
    replayGainAlbumPeak,
    trackRef,
    playability,
  ]);
}

@immutable
class GroupListeningQueueState {
  const GroupListeningQueueState({
    required this.queueVersion,
    this.currentIndex,
    this.entries = const <GroupListeningQueueEntry>[],
  });

  final int queueVersion;
  final int? currentIndex;
  final List<GroupListeningQueueEntry> entries;

  GroupListeningQueueEntry? get currentEntry {
    final index = currentIndex;
    if (index == null || index < 0 || index >= entries.length) {
      return null;
    }
    return entries[index];
  }

  String? get currentSongId => currentEntry?.songId;

  GroupListeningQueueState copyWith({
    int? queueVersion,
    int? currentIndex,
    List<GroupListeningQueueEntry>? entries,
  }) {
    return GroupListeningQueueState(
      queueVersion: queueVersion ?? this.queueVersion,
      currentIndex: currentIndex ?? this.currentIndex,
      entries: entries ?? this.entries,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningQueueState &&
          runtimeType == other.runtimeType &&
          queueVersion == other.queueVersion &&
          currentIndex == other.currentIndex &&
          listEquals(entries, other.entries);

  @override
  int get hashCode =>
      Object.hash(queueVersion, currentIndex, Object.hashAll(entries));
}
