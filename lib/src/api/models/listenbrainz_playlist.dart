class ListenBrainzTokenDetails {
  const ListenBrainzTokenDetails({
    required this.valid,
    this.userName,
  });

  final bool valid;
  final String? userName;
}

class ListenBrainzPlaylist {
  const ListenBrainzPlaylist({
    required this.identifier,
    required this.title,
    required this.tracks,
    this.creator,
    this.description,
    this.date,
    this.image,
    this.visibility,
    this.collaborators = const <String>[],
    this.raw = const <String, dynamic>{},
  });

  factory ListenBrainzPlaylist.fromJson(Map<String, dynamic> json) {
    final playlist = _firstMap(json, const <String>['playlist']) ?? json;
    final identifiers = _stringList(playlist['identifier']);
    final identifier =
        _stringValue(playlist['playlist_mbid']) ??
        _stringValue(playlist['mbid']) ??
        _mbidFromIdentifiers(identifiers) ??
        identifiers.firstOrNull ??
        _stringValue(playlist['id']) ??
        '';
    final trackList =
        _firstMap(playlist, const <String>['track']) ??
        _firstMap(playlist, const <String>['trackList']) ??
        const <String, dynamic>{};
    final tracks = _mapList(
      trackList['track'],
    ).map(ListenBrainzPlaylistTrack.fromJson).toList(growable: false);

    return ListenBrainzPlaylist(
      identifier: identifier,
      title: _stringValue(playlist['title']) ?? 'ListenBrainz playlist',
      creator: _stringValue(playlist['creator']),
      description:
          _stringValue(playlist['annotation']) ??
          _stringValue(playlist['description']),
      date: _parseDate(_stringValue(playlist['date'])),
      image: _stringValue(playlist['image']),
      visibility:
          _stringValue(
            playlist['extension']?['https://musicbrainz.org/doc/jspf#playlist']?['public'],
          ) ??
          _stringValue(playlist['public']),
      collaborators: _stringList(playlist['collaborator']),
      tracks: tracks,
      raw: Map<String, dynamic>.from(playlist),
    );
  }

  final String identifier;
  final String title;
  final String? creator;
  final String? description;
  final DateTime? date;
  final String? image;
  final String? visibility;
  final List<String> collaborators;
  final List<ListenBrainzPlaylistTrack> tracks;
  final Map<String, dynamic> raw;
}

class ListenBrainzPlaylistTrack {
  const ListenBrainzPlaylistTrack({
    required this.title,
    this.creator,
    this.album,
    this.durationMs,
    this.identifiers = const <String>[],
    this.recordingMbid,
    this.recordingMsid,
    this.image,
    this.raw = const <String, dynamic>{},
  });

  factory ListenBrainzPlaylistTrack.fromJson(Map<String, dynamic> json) {
    final identifiers = _stringList(json['identifier']);
    final extension = _flattenMaps(json['extension']);
    final additionalMetadata = _flattenMaps(extension['additional_metadata']);
    return ListenBrainzPlaylistTrack(
      title:
          _stringValue(json['title']) ??
          _stringValue(additionalMetadata['track_name']) ??
          _stringValue(additionalMetadata['recording_name']) ??
          'Unknown track',
      creator:
          _stringValue(json['creator']) ??
          _stringValue(additionalMetadata['artist_name']),
      album:
          _stringValue(json['album']) ??
          _stringValue(additionalMetadata['release_name']),
      durationMs:
          _intValue(json['duration']) ??
          _intValue(additionalMetadata['duration_ms']) ??
          (_intValue(additionalMetadata['duration']) == null
              ? null
              : _intValue(additionalMetadata['duration'])! * 1000),
      identifiers: identifiers,
      recordingMbid:
          _stringValue(additionalMetadata['recording_mbid']) ??
          _recordingMbidFromIdentifiers(identifiers),
      recordingMsid: _stringValue(additionalMetadata['recording_msid']),
      image:
          _stringValue(json['image']) ??
          _stringValue(additionalMetadata['caa_id']) ??
          _stringValue(additionalMetadata['release_mbid']),
      raw: Map<String, dynamic>.from(json),
    );
  }

  final String title;
  final String? creator;
  final String? album;
  final int? durationMs;
  final List<String> identifiers;
  final String? recordingMbid;
  final String? recordingMsid;
  final String? image;
  final Map<String, dynamic> raw;

  int? get durationSeconds => durationMs == null ? null : durationMs! ~/ 1000;
}

List<ListenBrainzPlaylist> parseListenBrainzPlaylistList(
  Map<String, dynamic> json,
) {
  final root = _firstMap(json, const <String>['playlists']) ?? json;
  final rawPlaylists = _mapList(root['playlist']);
  if (rawPlaylists.isNotEmpty) {
    return rawPlaylists
        .map(ListenBrainzPlaylist.fromJson)
        .where((playlist) => playlist.identifier.trim().isNotEmpty)
        .toList(growable: false);
  }
  final single = _firstMap(json, const <String>['playlist']);
  if (single == null) {
    return const <ListenBrainzPlaylist>[];
  }
  final playlist = ListenBrainzPlaylist.fromJson(single);
  return playlist.identifier.trim().isEmpty
      ? const <ListenBrainzPlaylist>[]
      : <ListenBrainzPlaylist>[playlist];
}

Map<String, dynamic>? _firstMap(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
  }
  return null;
}

Map<String, dynamic> _flattenMaps(Object? value) {
  if (value is! Map) {
    return const <String, dynamic>{};
  }
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.value is Map) {
      result.addAll(Map<String, dynamic>.from(entry.value as Map));
    } else {
      result[entry.key.toString()] = entry.value;
    }
  }
  return result;
}

List<Map<String, dynamic>> _mapList(Object? value) {
  if (value is List) {
    return value
        .whereType<Map<Object?, Object?>>()
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
  }
  if (value is Map) {
    return <Map<String, dynamic>>[Map<String, dynamic>.from(value)];
  }
  return const <Map<String, dynamic>>[];
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return value
        .map(_stringValue)
        .whereType<String>()
        .where((item) => item.trim().isNotEmpty)
        .toList(growable: false);
  }
  final single = _stringValue(value);
  return single == null || single.trim().isEmpty
      ? const <String>[]
      : <String>[single];
}

String? _stringValue(Object? value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '');
}

DateTime? _parseDate(String? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value);
}

String? _mbidFromIdentifiers(List<String> identifiers) {
  for (final identifier in identifiers) {
    final match = RegExp(
      '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
    ).firstMatch(identifier);
    if (match != null) {
      return match.group(1);
    }
  }
  return null;
}

String? _recordingMbidFromIdentifiers(List<String> identifiers) {
  for (final identifier in identifiers) {
    if (!identifier.contains('/recording/')) {
      continue;
    }
    final mbid = _mbidFromIdentifiers(<String>[identifier]);
    if (mbid != null) {
      return mbid;
    }
  }
  return null;
}
