import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/api/server_create_recovery.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/local_radio_station_dao.dart';

class RadioStationActions {
  new({
    required this._localStations,
    required this._api,
    required this._onServerChanged,
  });

  final _createRecovery = ServerCreateRecovery<InternetRadioStation>();

  final LocalRadioStationDao _localStations;
  final SubsonicApiClient? _api;
  final void Function() _onServerChanged;

  /// Saves a station. [moveToServer] uploads the device station [existing]:
  /// the device row is deleted only after a successful create if unchanged.
  Future<({bool deviceCopyKept})> save({
    InternetRadioStation? existing,
    required bool isLocal,
    bool moveToServer = false,
    required String name,
    required String streamUrl,
    String? homePageUrl,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Station name is required');
    }
    final stream = _validateUrl(streamUrl, 'streamUrl');
    final homepage = homePageUrl?.trim();
    final validatedHomepage = homepage == null || homepage.isEmpty
        ? null
        : _validateUrl(homepage, 'homePageUrl');
    if (isLocal && !moveToServer) {
      await _localStations.upsert(
        id: existing?.id,
        name: trimmedName,
        streamUrl: stream,
        homePageUrl: validatedHomepage,
      );
      return (deviceCopyKept: false);
    }
    var deviceCopyKept = false;
    final api = _requireApi();
    if (moveToServer && existing != null) {
      final resolved = await _createRecovery.run(
        existing.id,
        snapshot: existing,
        name: trimmedName,
        list: () async => [
          for (final row in await api.getInternetRadioStations())
            (id: row.id, name: row.name),
        ],
        create: () async {
          await api.createInternetRadioStation(
            name: trimmedName,
            streamUrl: stream,
            homepageUrl: validatedHomepage,
          );
          return null;
        },
      );
      deviceCopyKept = await _localStations.transaction(() async {
        final rows = await _localStations.watchAll().first;
        final current = rows.where((row) => row.id == existing.id).firstOrNull;
        final snapshot = resolved.snapshot;
        if (current != null &&
            (current.name != snapshot.name ||
                current.streamUrl != snapshot.streamUrl ||
                current.homePageUrl != snapshot.homePageUrl)) {
          return true;
        }
        await _localStations.deleteStation(existing.id);
        return false;
      });
      if (!deviceCopyKept) _createRecovery.complete(existing.id);
    } else if (existing == null) {
      await api.createInternetRadioStation(
        name: trimmedName,
        streamUrl: stream,
        homepageUrl: validatedHomepage,
      );
    } else {
      await api.updateInternetRadioStation(
        id: existing.id,
        name: trimmedName,
        streamUrl: stream,
        homepageUrl: validatedHomepage,
      );
    }
    _onServerChanged();
    return (deviceCopyKept: deviceCopyKept);
  }

  Future<void> delete(
    InternetRadioStation station, {
    required bool isLocal,
  }) async {
    if (isLocal) {
      await _localStations.deleteStation(station.id);
      return;
    }
    await _requireApi().deleteInternetRadioStation(station.id);
    _onServerChanged();
  }

  SubsonicApiClient _requireApi() =>
      _api ?? (throw StateError('No server connection available'));

  String _validateUrl(String value, String field) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw ArgumentError.value(
        value,
        field,
        'An absolute HTTP(S) URL is required',
      );
    }
    return trimmed;
  }
}
