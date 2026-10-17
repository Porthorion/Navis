import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:navis/src/common/preset_names.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';

/// A partial appearance snapshot. Null fields preserve current settings.
/// Explicitly cleared nullable settings use the corresponding clear flag.
@immutable
class AppearanceSnapshot {
  const new({
    this.themeMode,
    this.oledForAuto,
    this.colorStyle,
    this.colorSchemeSeed,
    this.dynamicAlbumColorEnabled,
    this.nightScheduleEnabled,
    this.nightScheduleStartMinutes,
    this.nightScheduleEndMinutes,
    this.albumArtShade,
    this.albumArtColoredShade,
    this.colorVividness,
    this.surfaceDepthLight,
    this.surfaceDepthDark,
    this.surfaceTintLight,
    this.surfaceTintDark,
    this.controlColor,
    this.flatSurfaces,
    this.flatAreas,
    this.cornerStyle,
    this.coverArtShape,
    this.nowPlayingArtShape,
    this.artistCardShape,
    this.gridArtworkSize,
    this.albumGridDensity,
    this.density,
    this.artistViewMode,
    this.nowPlayingBackground,
    this.clearColorSchemeSeed = false,
    this.clearAlbumGridDensity = false,
  });

  factory capture(AppSettingsModel s) => AppearanceSnapshot(
    themeMode: s.themeMode,
    oledForAuto: s.oledForAuto,
    colorStyle: s.colorStyle,
    colorSchemeSeed: s.colorSchemeSeed,
    dynamicAlbumColorEnabled: s.dynamicAlbumColorEnabled,
    nightScheduleEnabled: s.nightScheduleEnabled,
    nightScheduleStartMinutes: s.nightScheduleStartMinutes,
    nightScheduleEndMinutes: s.nightScheduleEndMinutes,
    albumArtShade: s.albumArtShade,
    albumArtColoredShade: s.albumArtColoredShade,
    colorVividness: s.colorVividness,
    surfaceDepthLight: s.surfaceDepthLight,
    surfaceDepthDark: s.surfaceDepthDark,
    surfaceTintLight: s.surfaceTintLight,
    surfaceTintDark: s.surfaceTintDark,
    controlColor: s.controlColor,
    flatSurfaces: s.flatSurfaces,
    flatAreas: s.flatAreas.bits,
    cornerStyle: s.cornerStyle.name,
    coverArtShape: s.coverArtShape,
    nowPlayingArtShape: s.nowPlayingArtShape,
    artistCardShape: s.artistCardShape,
    gridArtworkSize: s.gridArtworkSize.name,
    albumGridDensity: s.albumGridDensity,
    density: s.density.storageKey,
    artistViewMode: s.artistViewMode,
    nowPlayingBackground: s.nowPlayingBackground.storageKey,
    clearColorSchemeSeed: s.colorSchemeSeed == null,
    clearAlbumGridDensity: s.albumGridDensity == null,
  );

  factory fromJson(Map<String, dynamic> raw) => AppearanceSnapshot(
    themeMode: _choice(raw['themeMode'], const [
      'system',
      'light',
      'dark',
      'oled',
    ]),
    oledForAuto: _boolean(raw['oledForAuto']),
    colorStyle: _choice(raw['colorStyle'], const [
      'neutral',
      'pastel',
      'immersive',
      'night',
    ]),
    colorSchemeSeed: _integer(raw['colorSchemeSeed'], 0, 4294967295),
    dynamicAlbumColorEnabled: _boolean(raw['dynamicAlbumColorEnabled']),
    nightScheduleEnabled: _boolean(raw['nightScheduleEnabled']),
    nightScheduleStartMinutes: _integer(
      raw['nightScheduleStartMinutes'],
      0,
      1439,
    ),
    nightScheduleEndMinutes: _integer(raw['nightScheduleEndMinutes'], 0, 1439),
    albumArtShade: _boolean(raw['albumArtShade']),
    albumArtColoredShade: _boolean(raw['albumArtColoredShade']),
    colorVividness: _integer(raw['colorVividness'], -5, 5),
    surfaceDepthLight: _integer(raw['surfaceDepthLight'], -5, 5),
    surfaceDepthDark: _integer(raw['surfaceDepthDark'], -5, 5),
    surfaceTintLight: _integer(raw['surfaceTintLight'], 0, 5),
    surfaceTintDark: _integer(raw['surfaceTintDark'], 0, 5),
    controlColor: _choice(raw['controlColor'], const ['accent', 'white']),
    flatSurfaces: _boolean(raw['flatSurfaces']),
    flatAreas: _integer(raw['flatAreas'], 0, 7),
    cornerStyle: _choice(raw['cornerStyle'], const [
      'rounded',
      'soft',
      'square',
    ]),
    coverArtShape: _choice(raw['coverArtShape'], const [
      'square',
      'rounded',
      'circle',
    ]),
    nowPlayingArtShape: _choice(raw['nowPlayingArtShape'], const [
      'square',
      'rounded',
      'circle',
    ]),
    artistCardShape: _choice(raw['artistCardShape'], const [
      'square',
      'rounded',
      'circle',
    ]),
    gridArtworkSize: _choice(raw['gridArtworkSize'], const [
      'auto',
      'small',
      'medium',
      'large',
    ]),
    albumGridDensity: _integer(raw['albumGridDensity'], 1, 100),
    density: _choice(raw['density'], const ['comfortable', 'compact']),
    artistViewMode: _choice(raw['artistViewMode'], const ['list', 'grid']),
    nowPlayingBackground: _choice(raw['nowPlayingBackground'], const [
      'tinted',
      'artwork',
      'plain',
    ]),
    clearColorSchemeSeed:
        raw.containsKey('colorSchemeSeed') && raw['colorSchemeSeed'] == null,
    clearAlbumGridDensity:
        raw.containsKey('albumGridDensity') && raw['albumGridDensity'] == null,
  );

  final String? themeMode;
  final bool? oledForAuto;
  final String? colorStyle;
  final int? colorSchemeSeed;
  final bool? dynamicAlbumColorEnabled;
  final bool? nightScheduleEnabled;
  final int? nightScheduleStartMinutes;
  final int? nightScheduleEndMinutes;
  final bool? albumArtShade;
  final bool? albumArtColoredShade;
  final int? colorVividness;
  final int? surfaceDepthLight;
  final int? surfaceDepthDark;
  final int? surfaceTintLight;
  final int? surfaceTintDark;
  final String? controlColor;
  final bool? flatSurfaces;
  final int? flatAreas;
  final String? cornerStyle;
  final String? coverArtShape;
  final String? nowPlayingArtShape;
  final String? artistCardShape;
  final String? gridArtworkSize;
  final int? albumGridDensity;
  final String? density;
  final String? artistViewMode;
  final String? nowPlayingBackground;
  final bool clearColorSchemeSeed;
  final bool clearAlbumGridDensity;

  Map<String, Object?> toJson() => {
    if (themeMode != null) 'themeMode': themeMode,
    if (oledForAuto != null) 'oledForAuto': oledForAuto,
    if (colorStyle != null) 'colorStyle': colorStyle,
    if (colorSchemeSeed != null || clearColorSchemeSeed)
      'colorSchemeSeed': colorSchemeSeed,
    if (dynamicAlbumColorEnabled != null)
      'dynamicAlbumColorEnabled': dynamicAlbumColorEnabled,
    if (nightScheduleEnabled != null)
      'nightScheduleEnabled': nightScheduleEnabled,
    if (nightScheduleStartMinutes != null)
      'nightScheduleStartMinutes': nightScheduleStartMinutes,
    if (nightScheduleEndMinutes != null)
      'nightScheduleEndMinutes': nightScheduleEndMinutes,
    if (albumArtShade != null) 'albumArtShade': albumArtShade,
    if (albumArtColoredShade != null)
      'albumArtColoredShade': albumArtColoredShade,
    if (colorVividness != null) 'colorVividness': colorVividness,
    if (surfaceDepthLight != null) 'surfaceDepthLight': surfaceDepthLight,
    if (surfaceDepthDark != null) 'surfaceDepthDark': surfaceDepthDark,
    if (surfaceTintLight != null) 'surfaceTintLight': surfaceTintLight,
    if (surfaceTintDark != null) 'surfaceTintDark': surfaceTintDark,
    if (controlColor != null) 'controlColor': controlColor,
    if (flatSurfaces != null) 'flatSurfaces': flatSurfaces,
    if (flatAreas != null) 'flatAreas': flatAreas,
    if (cornerStyle != null) 'cornerStyle': cornerStyle,
    if (coverArtShape != null) 'coverArtShape': coverArtShape,
    if (nowPlayingArtShape != null) 'nowPlayingArtShape': nowPlayingArtShape,
    if (artistCardShape != null) 'artistCardShape': artistCardShape,
    if (gridArtworkSize != null) 'gridArtworkSize': gridArtworkSize,
    if (albumGridDensity != null || clearAlbumGridDensity)
      'albumGridDensity': albumGridDensity,
    if (density != null) 'density': density,
    if (artistViewMode != null) 'artistViewMode': artistViewMode,
    if (nowPlayingBackground != null)
      'nowPlayingBackground': nowPlayingBackground,
  };

  @override
  bool operator ==(Object other) =>
      other is AppearanceSnapshot &&
      const DeepCollectionEquality().equals(toJson(), other.toJson());
  @override
  int get hashCode => const DeepCollectionEquality().hash(toJson());
}

@immutable
class AppearanceLook {
  const new({
    required this.id,
    required this.name,
    this.version = 1,
    required this.snapshot,
  });
  final String id;
  final String name;
  final int version;
  final AppearanceSnapshot snapshot;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'snapshot': snapshot.toJson(),
  };
  static AppearanceLook? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    final id = raw['id'];
    final name = raw['name'];
    final snapshot = raw['snapshot'];
    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        snapshot is! Map<String, dynamic> ||
        validatePresetName(
              name,
              presets: const [],
              reservedNames: const {'default'},
            ) !=
            null) {
      return null;
    }
    return AppearanceLook(
      id: id,
      name: name.trim(),
      snapshot: AppearanceSnapshot.fromJson(snapshot),
    );
  }
}

/// The Look the current appearance is on.
///
/// Several Looks can hold the same appearance, so the explicitly chosen one
/// ([prefer], else the stored selection) wins while it still matches; any
/// other matching Look comes next, and a changed appearance is Custom (null).
String? matchingAppearanceLookId(AppSettingsModel settings, {String? prefer}) {
  final current = AppearanceSnapshot.capture(settings).toJson();
  // Missing saved fields preserve current settings and do not make a Look Custom.
  bool matches(AppearanceLook look) => look.snapshot.toJson().entries.every(
    (entry) => current[entry.key] == entry.value,
  );
  final chosen = prefer ?? settings.selectedAppearanceLookId;
  final looks = settings.appearanceLooks;
  if (chosen != null &&
      looks.any((look) => look.id == chosen && matches(look))) {
    return chosen;
  }
  return looks.where(matches).firstOrNull?.id;
}

/// The Look to store as selected: the one the appearance is on, else the one
/// it was last on ([prefer], else the stored selection) while it still exists.
/// A changed (Custom) appearance keeps that origin so Update has its target.
String? storedAppearanceLookId(AppSettingsModel settings, {String? prefer}) {
  final matching = matchingAppearanceLookId(settings, prefer: prefer);
  if (matching != null) return matching;
  final chosen = prefer ?? settings.selectedAppearanceLookId;
  return settings.appearanceLooks.any((look) => look.id == chosen)
      ? chosen
      : null;
}

List<AppearanceLook> decodeAppearanceLooks(String raw) => _decodePresets(
  raw,
  AppearanceLook.fromJson,
  (p) => (id: p.id, name: p.name),
);

List<T> _decodePresets<T>(
  String raw,
  T? Function(Object?) decode,
  ({String id, String name}) Function(T) identity,
) {
  try {
    final json = jsonDecode(raw);
    if (json is! List) {
      return const [];
    }
    final result = <T>[];
    final ids = <String>{};
    final names = <String>{};
    for (final item in json) {
      final preset = decode(item);
      if (preset == null) continue;
      final key = identity(preset);
      if (ids.contains(key.id) || names.contains(key.name.toLowerCase())) {
        continue;
      }
      ids.add(key.id);
      names.add(key.name.toLowerCase());
      result.add(preset);
    }
    return List.unmodifiable(result);
  } on FormatException {
    return const [];
  }
}

int? _integer(Object? value, int min, int max) =>
    value is int && value >= min && value <= max ? value : null;
bool? _boolean(Object? value) => value is bool ? value : null;
String? _choice(Object? value, List<String> choices) =>
    value is String && choices.contains(value) ? value : null;
List<int>? _accentSeeds(Object? value) =>
    value is List && value.every((v) => _integer(v, 0, 0xFFFFFFFF) != null)
    ? List<int>.unmodifiable(value.cast<int>())
    : null;
List<int> decodeAccentSeeds(String? raw) {
  if (raw == null) {
    return const [];
  }
  try {
    return _accentSeeds(jsonDecode(raw)) ?? const [];
  } on FormatException {
    return const [];
  }
}
