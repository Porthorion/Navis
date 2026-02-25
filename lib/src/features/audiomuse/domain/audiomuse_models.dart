import 'package:flutter/foundation.dart';

/// Configuration for the AudioMuse AI server connection.
@immutable
class AudioMuseConfig {
  const AudioMuseConfig({
    required this.serverUrl,
    this.apiKey,
    required this.enabled,
  });

  /// Base URL of the AudioMuse server (e.g. `https://audiomuse.example.com`).
  final String serverUrl;

  /// Optional API key for authentication.
  final String? apiKey;

  /// Whether AudioMuse integration is enabled.
  final bool enabled;

  /// Returns `true` when the configuration is complete enough to attempt
  /// a connection (URL non-empty and feature enabled).
  bool get isConfigured => enabled && serverUrl.trim().isNotEmpty;

  AudioMuseConfig copyWith({
    String? serverUrl,
    String? apiKey,
    bool? enabled,
    bool clearApiKey = false,
  }) {
    return AudioMuseConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      apiKey: clearApiKey ? null : apiKey ?? this.apiKey,
      enabled: enabled ?? this.enabled,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioMuseConfig &&
          runtimeType == other.runtimeType &&
          serverUrl == other.serverUrl &&
          apiKey == other.apiKey &&
          enabled == other.enabled;

  @override
  int get hashCode => Object.hash(serverUrl, apiKey, enabled);

  @override
  String toString() =>
      'AudioMuseConfig(serverUrl: $serverUrl, enabled: $enabled)';
}

/// A recommendation result from the AudioMuse API.
@immutable
class AudioMuseRecommendation {
  const AudioMuseRecommendation({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.coverArtId,
    this.score,
  });

  factory AudioMuseRecommendation.fromJson(Map<String, dynamic> json) {
    return AudioMuseRecommendation(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      coverArtId: json['coverArtId'] as String?,
      score: (json['score'] as num?)?.toDouble(),
    );
  }

  /// The Subsonic song/album/artist ID.
  final String id;

  /// Display title.
  final String title;

  /// Artist name (for songs/albums).
  final String? artist;

  /// Album name (for songs).
  final String? album;

  /// Cover art ID for image display.
  final String? coverArtId;

  /// Relevance score (0.0–1.0), higher = more relevant.
  final double? score;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioMuseRecommendation &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// An AI-generated mix result containing a list of song IDs.
@immutable
class AudioMuseMix {
  const AudioMuseMix({
    required this.name,
    required this.songIds,
    this.description,
  });

  factory AudioMuseMix.fromJson(Map<String, dynamic> json) {
    return AudioMuseMix(
      name: json['name'] as String? ?? 'AI Mix',
      songIds:
          (json['songIds'] as List<dynamic>?)
              ?.map((id) => id.toString())
              .toList(growable: false) ??
          const <String>[],
      description: json['description'] as String?,
    );
  }

  /// Display name for the generated mix.
  final String name;

  /// Ordered list of Subsonic song IDs.
  final List<String> songIds;

  /// Optional description of the mix.
  final String? description;
}

/// Health check response from the AudioMuse server.
@immutable
class AudioMuseHealth {
  const AudioMuseHealth({
    required this.healthy,
    this.version,
  });

  factory AudioMuseHealth.fromJson(Map<String, dynamic> json) {
    return AudioMuseHealth(
      healthy: json['healthy'] as bool? ?? false,
      version: json['version'] as String?,
    );
  }

  final bool healthy;
  final String? version;
}
