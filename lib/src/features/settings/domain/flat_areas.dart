import 'package:flutter/foundation.dart';

/// Areas affected by the Flat Surfaces switch.
@immutable
class FlatAreas {
  const new({
    this.surfaces = true,
    this.nowPlaying = true,
    this.artworkText = true,
  });

  /// Decodes the persisted mask; only bits 1, 2 and 4 are supported.
  factory fromBits(int bits) {
    RangeError.checkValueInInterval(bits, 0, 7, 'bits');
    return FlatAreas(
      surfaces: bits & 1 != 0,
      nowPlaying: bits & 2 != 0,
      artworkText: bits & 4 != 0,
    );
  }

  final bool surfaces;
  final bool nowPlaying;
  final bool artworkText;

  int get bits =>
      (surfaces ? 1 : 0) | (nowPlaying ? 2 : 0) | (artworkText ? 4 : 0);

  FlatAreas copyWith({bool? surfaces, bool? nowPlaying, bool? artworkText}) =>
      FlatAreas(
        surfaces: surfaces ?? this.surfaces,
        nowPlaying: nowPlaying ?? this.nowPlaying,
        artworkText: artworkText ?? this.artworkText,
      );

  @override
  bool operator ==(Object other) => other is FlatAreas && bits == other.bits;

  @override
  int get hashCode => bits.hashCode;
}
