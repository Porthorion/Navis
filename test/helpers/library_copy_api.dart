import 'package:dio/dio.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';

/// A Subsonic client whose getSong maps a remote id to a library copy, the way
/// a server with a remote catalogue does. [copies] maps remote id to copy id;
/// an id it lacks answers with itself (no library copy).
class LibraryCopyApiClient extends SubsonicApiClient {
  new(this.copies)
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'test',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final Map<String, String> copies;

  @override
  Future<Song> getSong(String id, {CancelToken? cancelToken}) async =>
      Song(id: copies[id] ?? id, title: 'Title', artist: 'Artist');
}
