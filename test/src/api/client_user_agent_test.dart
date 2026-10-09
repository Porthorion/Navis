import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/utils/constants.dart';

void main() {
  test('external clients send the current app version as User-Agent', () async {
    final version = RegExp(
      '^version: ([^+]+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1)!;
    expect(AppConstants.userAgent, 'Navis/$version');
    final sent = <String>[];
    Dio transport(BaseOptions options) {
      final dio = Dio(options);
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            sent.add(request.headers['User-Agent'] as String);
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: request,
                statusCode: 200,
                data: <String, dynamic>{},
              ),
            );
          },
        ),
      );
      return dio;
    }

    await DeezerApiClient(dio: transport(DeezerApiClient.baseOptions))
        .searchArtists('Artist');
    await LastFmApiClient(
      apiKey: 'fake',
      dio: transport(LastFmApiClient.baseOptions),
    ).getArtistTopTracks(artist: 'Artist');
    await ListenBrainzApiClient(
      dio: transport(ListenBrainzApiClient.baseOptions),
    ).validateTokenDetails('fake');
    await LrclibClient(dio: transport(LrclibClient.baseOptions))
        .getLyrics(artist: 'Artist', title: 'Song');
    expect(sent, List.filled(4, AppConstants.userAgent));
  });
}
