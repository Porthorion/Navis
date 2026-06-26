import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/settings/data/install_source_service.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/features/settings/data/update_repository.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';

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
