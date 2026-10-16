import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/local_radio_station_dao.dart';

class RadioStationActions {
  new({
    required this._localStations,
    required this._api,
    required this._onServerChanged,
  });

  final LocalRadioStationDao _localStations;
  final SubsonicApiClient? _api;
  final void Function() _onServerChanged;

  Future<void> save({
    InternetRadioStation? existing,
    required bool isLocal,
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
    if (isLocal) {
      await _localStations.upsert(
        id: existing?.id,
        name: trimmedName,
        streamUrl: stream,
        homePageUrl: validatedHomepage,
      );
      return;
    }
    final api = _requireApi();
    if (existing == null) {
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
