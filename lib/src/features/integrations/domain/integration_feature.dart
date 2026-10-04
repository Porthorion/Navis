import 'dart:convert';

import 'package:flutter/foundation.dart';

/// What must hold before a service can be used, beyond the user's switches.
enum IntegrationVerification {
  /// The service needs no credential.
  none,

  /// A Last.fm API key: bundled at build, or a stored custom key that was
  /// validated when it was saved.
  lastFmApiKey,

  /// A ListenBrainz token that validated successfully. The existing 401/403
  /// handling clears the flag when the token stops working.
  listenBrainzToken,
}

/// An external service Navis can talk to besides the user's own server.
enum IntegrationService {
  deezer(
    key: 'deezer',
    displayName: 'Deezer',
    host: 'api.deezer.com',
    verification: IntegrationVerification.none,
  ),
  lastFm(
    key: 'lastfm',
    displayName: 'Last.fm',
    host: 'ws.audioscrobbler.com',
    verification: IntegrationVerification.lastFmApiKey,
  ),
  listenBrainz(
    key: 'listenbrainz',
    displayName: 'ListenBrainz',
    host: 'api.listenbrainz.org',
    verification: IntegrationVerification.listenBrainzToken,
  ),
  lrclib(
    key: 'lrclib',
    displayName: 'LRCLIB',
    host: 'lrclib.net',
    verification: IntegrationVerification.none,
  ),
  updates(
    key: 'updates',
    displayName: 'Update checks',
    host: 'git.porthorion.com',
    verification: IntegrationVerification.none,
  ),
  autoEq(
    key: 'autoeq',
    displayName: 'AutoEQ',
    host: 'raw.githubusercontent.com',
    verification: IntegrationVerification.none,
  ),
  radioMetadata(
    key: 'radio',
    displayName: 'Radio stations',
    verification: IntegrationVerification.none,
  ),
  serverLinkedArtwork(
    key: 'artwork',
    displayName: 'Server-linked artwork',
    verification: IntegrationVerification.none,
  );

  new({
    required this.key,
    required this.displayName,
    required this.verification,
    this.host,
  });

  /// Stable lowercase key, persisted and accepted by diagnostics.
  final String key;

  /// Brand or product name. Not localized.
  final String displayName;

  /// The host Navis contacts, or null when it varies (radio stream hosts,
  /// artwork URLs the user's server links to).
  final String? host;

  final IntegrationVerification verification;

  static IntegrationService? tryParse(String key) {
    for (final service in values) {
      if (service.key == key) return service;
    }
    return null;
  }
}

/// The settings column that already stores a feature's switch. Those columns
/// stay the source of truth, so no data moves and every existing reader and
/// diagnostics script keeps working.
enum IntegrationLegacyColumn {
  useLrclib,
  updateCheckEnabled,
  listenBrainzScrobblingEnabled,

  /// Stored inverted: `legacyInstantMixEnabled == true` means Same Vibes is
  /// off (Server Mix).
  legacyInstantMixEnabled;

  /// Whether the feature is on when the column holds [columnValue].
  bool featureEnabledFor({required bool columnValue}) =>
      this == legacyInstantMixEnabled ? !columnValue : columnValue;

  /// The column value that stores the feature as [featureEnabled].
  bool columnValueFor({required bool featureEnabled}) =>
      this == legacyInstantMixEnabled ? !featureEnabled : featureEnabled;
}

/// A single switchable use of an external service.
enum IntegrationFeature {
  deezerTopSongs('deezer.topSongs', IntegrationService.deezer),
  deezerArtistImages('deezer.artistImages', IntegrationService.deezer),
  deezerSimilarArtists('deezer.similarArtists', IntegrationService.deezer),
  deezerMissingAlbums('deezer.missingAlbums', IntegrationService.deezer),
  deezerNewReleases('deezer.newReleases', IntegrationService.deezer),
  deezerTrending('deezer.trending', IntegrationService.deezer),
  lastFmSameVibes(
    'lastfm.sameVibes',
    IntegrationService.lastFm,
    legacyColumn: IntegrationLegacyColumn.legacyInstantMixEnabled,
  ),
  lastFmRadio('lastfm.radio', IntegrationService.lastFm),
  lastFmTopSongs('lastfm.topSongs', IntegrationService.lastFm),
  listenBrainzScrobbling(
    'listenbrainz.scrobbling',
    IntegrationService.listenBrainz,
    legacyColumn: IntegrationLegacyColumn.listenBrainzScrobblingEnabled,
  ),
  listenBrainzFeedback(
    'listenbrainz.feedback',
    IntegrationService.listenBrainz,
  ),
  listenBrainzWeeklyPlaylists(
    'listenbrainz.weeklyPlaylists',
    IntegrationService.listenBrainz,
  ),
  lrclibLyrics(
    'lrclib.lyrics',
    IntegrationService.lrclib,
    legacyColumn: IntegrationLegacyColumn.useLrclib,
  ),
  updatesAutomatic(
    'updates.automatic',
    IntegrationService.updates,
    legacyColumn: IntegrationLegacyColumn.updateCheckEnabled,
  ),
  autoEqCatalogue('autoeq.catalogue', IntegrationService.autoEq),
  radioNowPlaying('radio.nowPlaying', IntegrationService.radioMetadata),
  artworkServerLinked(
    'artwork.serverLinked',
    IntegrationService.serverLinkedArtwork,
  );

  new(this.key, this.service, {this.legacyColumn});

  /// Stable key, `<service key>.<feature>`; persisted and accepted by
  /// diagnostics.
  final String key;

  final IntegrationService service;

  /// The existing settings column that stores this feature's switch, or null
  /// when the feature lives in the disabled-integrations JSON set.
  final IntegrationLegacyColumn? legacyColumn;

  static IntegrationFeature? tryParse(String key) {
    for (final feature in values) {
      if (feature.key == key) return feature;
    }
    return null;
  }

  static List<IntegrationFeature> forService(IntegrationService service) => [
    for (final feature in values)
      if (feature.service == service) feature,
  ];
}

/// Whether [key] names a service or feature.
bool isIntegrationKey(String key) =>
    IntegrationService.tryParse(key) != null ||
    IntegrationFeature.tryParse(key) != null;

/// Parses the `disabled_integrations` JSON into the set of known keys that
/// the JSON may hold: service keys and features without a legacy column.
/// Unknown keys, non-string entries and malformed JSON are ignored, so a
/// damaged value never disables or enables more than it names.
Set<String> parseDisabledIntegrationKeys(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>{};
    return <String>{
      for (final entry in decoded)
        if (entry is String && _isJsonStoredKey(entry)) entry,
    };
  } on FormatException {
    return const <String>{};
  }
}

/// Encodes [keys] as the canonical sorted JSON list.
String encodeDisabledIntegrationKeys(Iterable<String> keys) =>
    jsonEncode(keys.toSet().toList()..sort());

bool _isJsonStoredKey(String key) =>
    IntegrationService.tryParse(key) != null ||
    (IntegrationFeature.tryParse(key)?.legacyColumn == null &&
        IntegrationFeature.tryParse(key) != null);

/// Why a feature's switch cannot be changed.
enum IntegrationLockReason { masterOff, serviceOff, notVerified }

/// The user's integration choices and the credentials that gate them, as a
/// pure value. Disabled keys already include the features stored in legacy
/// columns, so callers never look at those columns.
@immutable
class IntegrationPolicy {
  const new({
    this.masterEnabled = true,
    this.disabledKeys = const <String>{},
    this.lastFmVerified = false,
    this.listenBrainzVerified = false,
  });

  /// Denies everything. Used while settings load or when they fail to load,
  /// so no request leaves before the user's choices are known.
  const new denyAll()
    : masterEnabled = false,
      disabledKeys = const <String>{},
      lastFmVerified = false,
      listenBrainzVerified = false;

  /// Builds the policy from stored settings.
  ///
  /// The four legacy columns are folded into the disabled keys through
  /// [IntegrationLegacyColumn]; the JSON set holds the rest.
  factory resolve({
    required bool masterEnabled,
    required String? disabledJson,
    required bool useLrclib,
    required bool updateCheckEnabled,
    required bool listenBrainzScrobblingEnabled,
    required bool legacyInstantMixEnabled,
    required bool lastFmVerified,
    required bool listenBrainzVerified,
  }) {
    final columnValues = <IntegrationLegacyColumn, bool>{
      IntegrationLegacyColumn.useLrclib: useLrclib,
      IntegrationLegacyColumn.updateCheckEnabled: updateCheckEnabled,
      IntegrationLegacyColumn.listenBrainzScrobblingEnabled:
          listenBrainzScrobblingEnabled,
      IntegrationLegacyColumn.legacyInstantMixEnabled: legacyInstantMixEnabled,
    };
    final disabled = <String>{...parseDisabledIntegrationKeys(disabledJson)};
    for (final feature in IntegrationFeature.values) {
      final column = feature.legacyColumn;
      if (column != null &&
          !column.featureEnabledFor(columnValue: columnValues[column]!)) {
        disabled.add(feature.key);
      }
    }
    return IntegrationPolicy(
      masterEnabled: masterEnabled,
      disabledKeys: Set.unmodifiable(disabled),
      lastFmVerified: lastFmVerified,
      listenBrainzVerified: listenBrainzVerified,
    );
  }

  /// The "Online services" switch. Off means Navis only talks to the user's
  /// server.
  final bool masterEnabled;

  /// Service keys and feature keys the user switched off.
  final Set<String> disabledKeys;

  final bool lastFmVerified;
  final bool listenBrainzVerified;

  bool isVerified(IntegrationService service) => switch (service.verification) {
    IntegrationVerification.none => true,
    IntegrationVerification.lastFmApiKey => lastFmVerified,
    IntegrationVerification.listenBrainzToken => listenBrainzVerified,
  };

  /// The user's own switch for [service], regardless of the master switch.
  bool isServiceSwitchOn(IntegrationService service) =>
      !disabledKeys.contains(service.key);

  /// Whether [service] may be contacted at all: the master switch and the
  /// service switch are on. Credentials are not considered; see [isVerified].
  bool isServiceEnabled(IntegrationService service) =>
      masterEnabled && isServiceSwitchOn(service);

  /// The user's own switch for [feature], regardless of master and service.
  bool isFeatureSwitchOn(IntegrationFeature feature) =>
      !disabledKeys.contains(feature.key);

  /// Whether the master, service and feature switches are all on. A feature
  /// that must work before its credential is checked, such as the validation
  /// itself, gates on this rather than [allows].
  bool isEnabled(IntegrationFeature feature) =>
      isServiceEnabled(feature.service) && isFeatureSwitchOn(feature);

  /// Whether [feature] may make requests now.
  bool allows(IntegrationFeature feature) =>
      isEnabled(feature) && isVerified(feature.service);

  /// Why [feature]'s switch cannot be changed, or null when it can. The
  /// master switch outranks the service switch, which outranks credentials.
  IntegrationLockReason? lockReason(IntegrationFeature feature) {
    if (!masterEnabled) return IntegrationLockReason.masterOff;
    if (!isServiceSwitchOn(feature.service)) {
      return IntegrationLockReason.serviceOff;
    }
    if (!isVerified(feature.service)) return IntegrationLockReason.notVerified;
    return null;
  }

  /// Why [service]'s own switch cannot be changed, or null when it can.
  IntegrationLockReason? serviceLockReason(IntegrationService service) {
    if (!masterEnabled) return IntegrationLockReason.masterOff;
    if (!isVerified(service)) return IntegrationLockReason.notVerified;
    return null;
  }

  /// Whether the user can change [feature]'s switch now: false when the
  /// master switch is off, the service is off, or the service is unverified.
  bool isUserToggleable(IntegrationFeature feature) =>
      lockReason(feature) == null;

  @override
  bool operator ==(Object other) =>
      other is IntegrationPolicy &&
      other.masterEnabled == masterEnabled &&
      other.lastFmVerified == lastFmVerified &&
      other.listenBrainzVerified == listenBrainzVerified &&
      setEquals(other.disabledKeys, disabledKeys);

  @override
  int get hashCode => Object.hash(
    masterEnabled,
    lastFmVerified,
    listenBrainzVerified,
    Object.hashAllUnordered(disabledKeys),
  );

  @override
  String toString() =>
      'IntegrationPolicy(master: $masterEnabled, disabled: $disabledKeys, '
      'lastFmVerified: $lastFmVerified, '
      'listenBrainzVerified: $listenBrainzVerified)';
}
