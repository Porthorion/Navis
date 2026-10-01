import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/settings/data/install_source_service.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/features/settings/data/update_repository.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _MockDio extends Mock implements Dio {}

class _FakeInstallSourceService extends InstallSourceService {
  _FakeInstallSourceService(this._installerPackage)
    : super(channel: const MethodChannel('test/distribution'));

  final String? _installerPackage;

  @override
  Future<InstallSourceInfo?> getInstallSource() async {
    return InstallSourceInfo(installerPackage: _installerPackage);
  }
}

class _MemoryUpdateCheckStore extends UpdateCheckStore {
  _MemoryUpdateCheckStore({required this.allowCheck});

  bool allowCheck;
  int recordCount = 0;

  @override
  Future<bool> shouldCheck({bool force = false}) async => force || allowCheck;

  @override
  Future<void> recordCheck([DateTime? checkedAt]) async {
    recordCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateRepository', () {
    late _MockDio dio;

    setUp(() {
      dio = _MockDio();
    });

    test('returns null on iOS', () async {
      if (!Platform.isIOS) {
        return;
      }

      final repository = UpdateRepository(dio: dio);
      final result = await repository.checkForUpdate(forceCheck: true);
      expect(result, isNull);
    });

    test(
      'returns store redirect delivery for Play installs on Android',
      () async {
        if (!Platform.isAndroid) {
          return;
        }

        when(
          () => dio.get<List<dynamic>>(
            any(),
            options: any(named: 'options'),
          ),
        ).thenAnswer(
          (_) async => Response<List<dynamic>>(
            data: [
              {
                'tag_name': 'v99.0.0',
                'prerelease': false,
                'html_url': 'https://example.com/release',
                'body': 'notes',
                'assets': [
                  {
                    'name': 'navis-v99.0.0.apk',
                    'browser_download_url': 'https://example.com/navis.apk',
                  },
                ],
              },
            ],
            requestOptions: RequestOptions(path: '/releases'),
            statusCode: 200,
          ),
        );

        final repository = UpdateRepository(
          dio: dio,
          installSourceService: _FakeInstallSourceService(
            'com.android.vending',
          ),
          updateCheckStore: _MemoryUpdateCheckStore(allowCheck: true),
        );

        final result = await repository.checkForUpdate(forceCheck: true);
        expect(result, isNotNull);
        expect(result!.delivery, UpdateDelivery.storeRedirect);
        expect(result.downloadUrl, isNull);
        expect(result.tagName, 'v99.0.0');
      },
    );

    test(
      'returns forgejo self-update for sideload installs on Android',
      () async {
        if (!Platform.isAndroid) {
          return;
        }

        when(
          () => dio.get<List<dynamic>>(
            any(),
            options: any(named: 'options'),
          ),
        ).thenAnswer(
          (_) async => Response<List<dynamic>>(
            data: [
              {
                'tag_name': 'v99.0.0',
                'prerelease': false,
                'html_url': 'https://example.com/release',
                'body': 'notes',
                'assets': [
                  {
                    'name': 'navis-v99.0.0.apk',
                    'browser_download_url': 'https://example.com/navis.apk',
                  },
                ],
              },
            ],
            requestOptions: RequestOptions(path: '/releases'),
            statusCode: 200,
          ),
        );

        final repository = UpdateRepository(
          dio: dio,
          installSourceService: _FakeInstallSourceService('com.android.shell'),
          updateCheckStore: _MemoryUpdateCheckStore(allowCheck: true),
        );

        final result = await repository.checkForUpdate(forceCheck: true);
        expect(result, isNotNull);
        expect(result!.delivery, UpdateDelivery.forgejoSelfUpdate);
        expect(result.downloadUrl, 'https://example.com/navis.apk');
      },
    );

    test('a release whose tag is not a version is never an update', () async {
      if (Platform.isIOS || Platform.isAndroid) {
        return;
      }
      PackageInfo.setMockInitialValues(
        appName: 'Navis',
        packageName: 'com.navis.app.navis',
        version: '1.4.0',
        buildNumber: '1',
        buildSignature: '',
      );
      Map<String, Object?> release(String tag) => <String, Object?>{
        'tag_name': tag,
        'prerelease': true,
        'html_url': 'https://example.com/$tag',
        'body': '',
        'assets': <Object?>[],
      };
      var releases = <Object?>[
        release('third-party-binaries'),
        release('v1.3.0'),
      ];
      when(
        () => dio.get<List<dynamic>>(any(), options: any(named: 'options')),
      ).thenAnswer(
        (_) async => Response<List<dynamic>>(
          data: releases,
          requestOptions: RequestOptions(path: '/releases'),
          statusCode: 200,
        ),
      );
      final repository = UpdateRepository(
        dio: dio,
        updateCheckStore: _MemoryUpdateCheckStore(allowCheck: true),
      );

      expect(
        await repository.checkForUpdate(forceCheck: true, updateChannel: 'dev'),
        isNull,
      );
      releases = <Object?>[release('third-party-binaries'), release('v1.4.1')];
      final update = await repository.checkForUpdate(
        forceCheck: true,
        updateChannel: 'dev',
      );
      expect(update?.tagName, 'v1.4.1');
    });

    test('skips network fetch when update check throttle is active', () async {
      if (Platform.isIOS) {
        return;
      }

      final repository = UpdateRepository(
        dio: dio,
        updateCheckStore: _MemoryUpdateCheckStore(allowCheck: false),
      );

      final throttled = await repository.checkForUpdate(forceCheck: false);
      expect(throttled, isNull);
      verifyNever(
        () => dio.get<List<dynamic>>(any(), options: any(named: 'options')),
      );
    });
  });
}
