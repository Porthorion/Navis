import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/features/settings/data/install_source_service.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/features/settings/data/update_install_mode.dart';
import 'package:navis/src/features/settings/data/update_repository.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/integrations/domain/update_source.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _MockDio extends Mock implements Dio;

class _FakeInstallSourceService extends InstallSourceService {
  new(this._installerPackage, this._primaryAbi)
    : super(channel: const MethodChannel('test/distribution'));

  final String? _installerPackage;
  final String? _primaryAbi;

  @override
  Future<InstallSourceInfo?> getInstallSource() async => InstallSourceInfo(
    installerPackage: _installerPackage,
    primaryAbi: _primaryAbi,
  );
}

class _MemoryUpdateCheckStore extends UpdateCheckStore {
  new({this.allowCheck = true});

  bool allowCheck;
  int recordCount = 0;
  String identity = 'stable/porthorion';

  @override
  Future<bool> selectSource(String value) async {
    final changed = value != identity;
    identity = value;
    if (changed) verifiedManifest = null;
    return changed;
  }

  Map<String, Object?>? verifiedManifest;

  @override
  Future<bool> shouldCheck({bool force = false}) async => force || allowCheck;

  @override
  Future<void> recordCheck([
    DateTime? checkedAt,
    String? sourceIdentity,
  ]) async => recordCount++;

  @override
  Future<Map<String, Object?>?> readVerifiedManifest() async =>
      verifiedManifest;

  @override
  Future<void> recordVerifiedManifest(
    Map<String, Object?> value, {
    String? sourceIdentity,
  }) async => verifiedManifest = value;

  @override
  Future<void> clearVerifiedManifest({String? sourceIdentity}) async =>
      verifiedManifest = null;
}

const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _assetUrl = '${AppConstants.updateBaseUrl}releases/v1.5.1/navis.apk';
const _opensslKey = 'w452ghSzhMIwM8lYSFKPFMvOC4CXx9E6ulYYbyG3dEM=';
const _opensslPayload =
    'eyJzY2hlbWEiOjEsImNoYW5uZWwiOiJzdGFibGUiLCJ2ZXJzaW9uIjoiOS45LjkiLCJ0YWciOiJ2OS45LjkiLCJhc3NldHMiOnt9fQ==';
const _opensslSignature =
    'LKWCp6BiymaWaAK3lGGUWZeNkjJuTQnK/22LnGGxgFZg7hOi+ay6kLFzrcZ+Mo05JjaOFtp7BZJ0jG/7Db4UAw==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ed25519 = Ed25519();
  late _MockDio dio;
  late SimpleKeyPair keyPair;
  late String publicKey;
  late _MemoryUpdateCheckStore store;
  late Map<String, Object?> payload;
  Object? envelope;
  late List<Options> requests;
  late List<String> urls;

  Future<Map<String, String>> sign(
    Map<String, Object?> value, {
    SimpleKeyPair? key,
  }) async {
    final bytes = utf8.encode(jsonEncode(value));
    final signature = await ed25519.sign(bytes, keyPair: key ?? keyPair);
    return {
      'payload': base64Encode(bytes),
      'signature': base64Encode(signature.bytes),
    };
  }

  UpdateRepository repository({
    UpdateSource source = UpdateSource.porthorion,
    bool isIOS = false,
    bool isAndroid = false,
    String? installer,
    String? primaryAbi,
    String? signingKey,
    UpdateInstallMode mode = UpdateInstallMode.linuxPortable,
    String arch = 'amd64',
    String rpmArch = 'x86_64',
  }) => UpdateRepository(
    dio: dio,
    source: source,
    signingPublicKey: signingKey ?? publicKey,
    updateCheckStore: store,
    isIOS: isIOS,
    isAndroid: isAndroid,
    installSourceService: _FakeInstallSourceService(installer, primaryAbi),
    installModeDetector: () => mode,
    linuxDebArch: () => arch,
    linuxRpmArch: () => rpmArch,
  );

  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Navis',
      packageName: 'com.navis.app.navis',
      version: '1.5.0+42',
      buildNumber: '42',
      buildSignature: '',
    );
    dio = _MockDio();
    store = _MemoryUpdateCheckStore();
    keyPair = await ed25519.newKeyPair();
    publicKey = base64Encode((await keyPair.extractPublicKey()).bytes);
    payload = {
      'schema': 1,
      'channel': 'stable',
      'version': '1.5.1',
      'tag': 'v1.5.1',
      'published_at': '2026-11-01T12:00:00Z',
      'notes': '**Release notes**',
      'notes_url': 'https://navis.porthorion.com/releases/v1.5.1',
      'assets': {
        for (final key in ['linuxPortable', 'androidApk', 'linuxDeb-amd64'])
          key: {'url': _assetUrl, 'sha256': _hash, 'size': 123},
      },
    };
    envelope = await sign(payload);
    requests = [];
    urls = [];
    when(() => dio.get<Object?>(any(), options: any(named: 'options')))
        .thenAnswer((invocation) async {
          urls.add(invocation.positionalArguments.first as String);
          requests.add(invocation.namedArguments[#options] as Options);
          return Response<Object?>(
            data: envelope,
            requestOptions: RequestOptions(path: urls.last),
            statusCode: 200,
          );
        });
  });

  test('GitHub verifies the envelope and maps only signed tag and filename', () async {
    final repo = repository(source: UpdateSource.github);
    final result = await repo.checkForUpdate();
    expect(
      urls.single,
      'https://github.com/Porthorion/Navis/releases/latest/download/manifest.json',
    );
    expect(
      result!.downloadUrl,
      'https://github.com/Porthorion/Navis/releases/download/v1.5.1/navis.apk',
    );
    expect(result.sha256, _hash);
    expect(result.size, 123);
    expect(repo.lastCheck!.url, urls.single);
    expect(repo.lastCheck!.signatureValid, isTrue);
  });

  test('GitHub manifest follows only checked release/CDN redirects', () async {
    when(() => dio.get<Object?>(any(), options: any(named: 'options')))
        .thenAnswer((invocation) async {
          final url = invocation.positionalArguments.first as String;
          urls.add(url);
          final options = invocation.namedArguments[#options] as Options;
          expect(options.followRedirects, isFalse);
          return Response<Object?>(
            requestOptions: RequestOptions(path: url),
            statusCode: urls.length == 1 ? 302 : 200,
            headers: Headers.fromMap(
              urls.length == 1
                  ? {
                      'location': [
                        'https://release-assets.githubusercontent.com/fixture/manifest.json',
                      ],
                    }
                  : {},
            ),
            data: urls.length == 1 ? null : envelope,
          );
        });
    final repo = repository(source: UpdateSource.github);
    expect((await repo.checkForUpdate())!.sha256, _hash);
    expect(urls.map((url) => Uri.parse(url).host), [
      'github.com',
      'release-assets.githubusercontent.com',
    ]);
    expect(repo.lastCheck!.url, urls.first);
  });

  test('GitHub rejects a tampered envelope', () async {
    final signed = envelope! as Map<String, String>;
    signed['payload'] = base64Encode(
      utf8.encode(jsonEncode({...payload, 'tag': 'v9.9.9'})),
    );
    final repo = repository(source: UpdateSource.github);
    expect(await repo.checkForUpdate(), isNull);
    expect(repo.lastCheck!.rejectReason, 'invalid_signature');
  });

  for (final source in UpdateSource.values) {
    test('$source rejects off-prefix signed assets', () async {
      (payload['assets']! as Map)['linuxPortable'] = {
        'url':
            'https://github.com/evil/Navis/releases/download/v1.5.1/navis.apk',
        'sha256': _hash,
        'size': 123,
      };
      envelope = await sign(payload);
      final repo = repository(source: source);
      expect(await repo.checkForUpdate(), isNull);
      expect(repo.lastCheck!.rejectReason, 'invalid_asset_url');
    });

    test('$source transport failure never falls back', () async {
      when(() => dio.get<Object?>(any(), options: any(named: 'options')))
          .thenAnswer((invocation) async {
            urls.add(invocation.positionalArguments.first as String);
            throw DioException(requestOptions: RequestOptions(path: urls.last));
          });
      final repo = repository(source: source);
      await expectLater(repo.checkForUpdate(), throwsA(isA<DioException>()));
      expect(urls, [UpdateRepository.manifestUrlFor('stable', source)]);
      expect(repo.lastCheck!.rejectReason, 'fetch_failed');
    });
  }

  test('dev ignores a stored GitHub preference', () async {
    payload['channel'] = 'dev';
    envelope = await sign(payload);
    final result = await repository(source: UpdateSource.github)
        .checkForUpdate(updateChannel: 'dev');
    expect(urls.single, UpdateRepository.manifestUrlFor('dev'));
    expect(result!.downloadUrl, _assetUrl);
  });

  test(
    'source switch bypasses throttle and discards old cached offer',
    () async {
      await repository().checkForUpdate();
      store.allowCheck = false;
      final switched = repository(source: UpdateSource.github);
      final result = await switched.checkForUpdate();
      expect(urls, hasLength(2));
      expect(
        urls.last,
        UpdateRepository.manifestUrlFor('stable', UpdateSource.github),
      );
      expect(switched.lastCheck!.fromCache, isFalse);
      expect(result!.downloadUrl, contains('/releases/download/v1.5.1/'));
    },
  );

  for (final suffix in [
    '?download=1',
    '#fragment',
    '%2Fhidden.apk',
    '%3Fdownload=1',
    '%23fragment',
  ]) {
    test('GitHub rejects signed asset basename carrying $suffix', () async {
      (payload['assets']! as Map)['linuxPortable'] = {
        'url': '$_assetUrl$suffix',
        'sha256': _hash,
        'size': 123,
      };
      envelope = await sign(payload);
      final repo = repository(source: UpdateSource.github);
      expect(await repo.checkForUpdate(), isNull);
      expect(repo.lastCheck!.rejectReason, 'invalid_asset_url');
      expect(repo.lastCheck!.signatureValid, isTrue);
    });
  }

  for (final tag in ['1.5.1', 'v1.5.2', 'v1.5.1-dev.1', 'latest']) {
    test('GitHub rejects signed tag that is not v<version>: $tag', () async {
      payload['tag'] = tag;
      envelope = await sign(payload);
      final repo = repository(source: UpdateSource.github);
      expect(await repo.checkForUpdate(), isNull);
      expect(repo.lastCheck!.rejectReason, 'malformed_payload');
      expect(repo.lastCheck!.signatureValid, isTrue);
    });
  }

  test(
    'GitHub rejects HTTP Location in the middle of a redirect chain',
    () async {
      when(
        () => dio.get<Object?>(any(), options: any(named: 'options')),
      ).thenAnswer((invocation) async {
        final url = invocation.positionalArguments.first as String;
        urls.add(url);
        return Response<Object?>(
          requestOptions: RequestOptions(path: url),
          statusCode: 302,
          headers: Headers.fromMap({
            'location': [
              if (urls.length == 1)
                'https://release-assets.githubusercontent.com/fixture/manifest.json'
              else
                'http://objects.githubusercontent.com/fixture/manifest.json',
            ],
          }),
        );
      });
      final repo = repository(source: UpdateSource.github);
      await expectLater(repo.checkForUpdate(), throwsA(isA<DioException>()));
      expect(urls.map((url) => Uri.parse(url).host), [
        'github.com',
        'release-assets.githubusercontent.com',
      ]);
      expect(repo.lastCheck!.rejectReason, 'fetch_failed');
    },
  );

  test('GitHub rejects signed tag traversal', () async {
    payload['tag'] = '../evil';
    envelope = await sign(payload);
    final repo = repository(source: UpdateSource.github);
    expect(await repo.checkForUpdate(), isNull);
    expect(repo.lastCheck!.rejectReason, 'malformed_payload');
  });

  test(
    'valid manifest supplies verified artifact and release metadata',
    () async {
      final repo = repository();
      final result = await repo.checkForUpdate();
      expect(result, isNotNull);
      expect(result!.tagName, 'v1.5.1');
      expect(result.downloadUrl, _assetUrl);
      expect(result.assetFileName, 'navis.apk');
      expect(result.sha256, _hash);
      expect(result.size, 123);
      expect(result.releaseNotes, '**Release notes**');
      expect(result.htmlUrl, payload['notes_url']);
      expect(result.delivery, UpdateDelivery.desktopSelfUpdate);
      expect(urls.single, UpdateRepository.manifestUrlFor('stable'));
      expect(requests.single.responseType, ResponseType.json);
      expect(requests.single.receiveTimeout, const Duration(seconds: 10));
      expect(requests.single.sendTimeout, const Duration(seconds: 10));
      expect(store.recordCount, 1);
      expect(repo.lastCheck!.signatureValid, isTrue);
      expect(repo.lastCheck!.payloadVersion, '1.5.1');
      expect(repo.lastCheck!.assetKey, 'linuxPortable');
      expect(repo.lastCheck!.rejectReason, isNull);
      expect(repo.lastCheck!.tag, 'v1.5.1');
      expect(repo.lastCheck!.timestamp.isUtc, isTrue);
    },
  );

  test(
    'manifest served without a JSON content type is still verified',
    () async {
      envelope = jsonEncode(envelope);
      final result = await repository().checkForUpdate();
      expect(result?.tagName, 'v1.5.1');
    },
  );

  test('iOS never fetches an update', () async {
    final repo = repository(isIOS: true);
    expect(await repo.checkForUpdate(forceCheck: true), isNull);
    expect(requests, isEmpty);
    expect(repo.lastCheck, isNull);
  });

  test('Play installs redirect without download integrity metadata', () async {
    final result = await repository(
      isAndroid: true,
      installer: 'com.android.vending',
      mode: UpdateInstallMode.androidApk,
    ).checkForUpdate();
    expect(result!.delivery, UpdateDelivery.storeRedirect);
    expect(result.downloadUrl, isNull);
    expect(result.sha256, isNull);
    expect(result.size, isNull);
  });

  test('Android sideload installs use self update', () async {
    final result = await repository(
      isAndroid: true,
      installer: 'com.android.shell',
      mode: UpdateInstallMode.androidApk,
    ).checkForUpdate();
    expect(result!.delivery, UpdateDelivery.selfUpdate);
    expect(result.downloadUrl, _assetUrl);
    expect(result.sha256, _hash);
    expect(result.size, 123);
  });

  for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
    test('Android $abi selects its signed split APK', () async {
      final splitUrl =
          '${AppConstants.updateBaseUrl}releases/v1.5.1/'
          'navis-v1.5.1-android-$abi.apk';
      (payload['assets']! as Map)['androidApk-$abi'] = {
        'url': splitUrl,
        'sha256': 'b' * 64,
        'size': 456,
      };
      envelope = await sign(payload);
      final repo = repository(
        isAndroid: true,
        mode: UpdateInstallMode.androidApk,
        primaryAbi: abi,
      );
      final result = await repo.checkForUpdate();
      expect(result!.downloadUrl, splitUrl);
      expect(result.assetFileName, 'navis-v1.5.1-android-$abi.apk');
      expect(result.sha256, 'b' * 64);
      expect(result.size, 456);
      expect(repo.lastCheck!.assetKey, 'androidApk-$abi');
    });
  }

  for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86', null]) {
    test('Android $abi without a matching split uses universal', () async {
      // An unrelated split must never replace the universal fallback.
      (payload['assets']! as Map)['androidApk-other'] = {
        'url': '${AppConstants.updateBaseUrl}wrong.apk',
        'sha256': 'b' * 64,
        'size': 456,
      };
      envelope = await sign(payload);
      final repo = repository(
        isAndroid: true,
        mode: UpdateInstallMode.androidApk,
        primaryAbi: abi,
      );
      final result = await repo.checkForUpdate();
      expect(result!.downloadUrl, _assetUrl);
      expect(result.sha256, _hash);
      expect(result.size, 123);
      expect(repo.lastCheck!.assetKey, 'androidApk');
    });
  }

  test('unknown ABI ignores even an identically named unknown split', () async {
    (payload['assets']! as Map)['androidApk-x86'] = {
      'url': '${AppConstants.updateBaseUrl}unsupported.apk',
      'sha256': 'b' * 64,
      'size': 456,
    };
    envelope = await sign(payload);
    final repo = repository(
      isAndroid: true,
      mode: UpdateInstallMode.androidApk,
      primaryAbi: 'x86',
    );
    expect((await repo.checkForUpdate())!.downloadUrl, _assetUrl);
    expect(repo.lastCheck!.assetKey, 'androidApk');
  });

  test(
    'invalid matching split is rejected before offering a download',
    () async {
      (payload['assets']! as Map)['androidApk-arm64-v8a'] = {
        'url': 'https://example.com/untrusted.apk',
        'sha256': _hash,
        'size': 123,
      };
      envelope = await sign(payload);
      final repo = repository(
        isAndroid: true,
        mode: UpdateInstallMode.androidApk,
        primaryAbi: 'arm64-v8a',
      );
      expect(await repo.checkForUpdate(), isNull);
      expect(repo.lastCheck!.assetKey, 'androidApk-arm64-v8a');
      expect(repo.lastCheck!.rejectReason, 'invalid_asset_url');
    },
  );

  test('only Check now marks requests user initiated', () async {
    final repo = repository();
    await repo.checkForUpdate();
    await repo.checkForUpdate(forceCheck: true);
    expect(requests[0].extra, isNot(contains(navisUserInitiatedExtraKey)));
    expect(requests[1].extra, containsPair(navisUserInitiatedExtraKey, true));
  });

  test('initial throttle skips network with no last check', () async {
    store = _MemoryUpdateCheckStore(allowCheck: false);
    final repo = repository();
    expect(await repo.checkForUpdate(), isNull);
    expect(requests, isEmpty);
    expect(repo.lastCheck, isNull);
  });

  test('throttle re-verifies the cached envelope without fetching or recording a check', () async {
    final repo = repository();
    final first = await repo.checkForUpdate();
    store.allowCheck = false;
    final throttled = await repo.checkForUpdate();
    expect(throttled!.tagName, first!.tagName);
    expect(throttled.version, '1.5.1');
    expect(throttled.downloadUrl, _assetUrl);
    expect(throttled.delivery, UpdateDelivery.desktopSelfUpdate);
    expect(requests, hasLength(1));
    expect(repo.lastCheck!.fromCache, isTrue);
    expect(store.recordCount, 1);
    expect(await repo.checkForUpdate(forceCheck: true), isNotNull);
    expect(requests, hasLength(2));
  });

  test(
    'cached verified update drops when the installed version catches up',
    () async {
      final repo = repository();
      await repo.checkForUpdate();
      PackageInfo.setMockInitialValues(
        appName: 'Navis',
        packageName: 'com.navis.app.navis',
        version: '1.5.1+43',
        buildNumber: '43',
        buildSignature: '',
      );
      store.allowCheck = false;
      expect(await repo.checkForUpdate(), isNull);
      expect(store.verifiedManifest, isNotNull);
    },
  );

  test(
    'a fresh fetch clears a cached update the manifest no longer offers',
    () async {
      final repo = repository();
      await repo.checkForUpdate();
      payload['version'] = '1.4.9';
      payload['tag'] = 'v1.4.9';
      envelope = await sign(payload);
      expect(await repo.checkForUpdate(forceCheck: true), isNull);
      store.allowCheck = false;
      expect(await repo.checkForUpdate(), isNull);
      expect(store.verifiedManifest, isNull);
    },
  );

  test('cached dev build survives a same-version installed build', () async {
    payload['channel'] = 'dev';
    payload['version'] = '1.5.0-dev+999';
    payload['build'] = 999;
    envelope = await sign(payload);
    final repo = repository();
    expect(await repo.checkForUpdate(updateChannel: 'dev'), isNotNull);
    store.allowCheck = false;
    expect((await repo.checkForUpdate(updateChannel: 'dev'))!.buildNumber, 999);
    PackageInfo.setMockInitialValues(
      appName: 'Navis',
      packageName: 'com.navis.app.navis',
      version: '1.5.0-dev',
      buildNumber: '999',
      buildSignature: '',
    );
    expect(await repo.checkForUpdate(updateChannel: 'dev'), isNull);
  });

  for (final field in ['payload', 'signature']) {
    test('tampered cached $field cannot supply an update', () async {
      final repo = repository();
      await repo.checkForUpdate();
      final signed = envelope! as Map<String, String>;
      final bytes = base64Decode(signed[field]!);
      bytes[0] ^= 1;
      store.verifiedManifest = {...signed, field: base64Encode(bytes)};
      store.allowCheck = false;
      expect(await repo.checkForUpdate(), isNull);
      expect(requests, hasLength(1));
    });
  }

  test('cache retains the signed envelope exactly', () async {
    await repository().checkForUpdate();
    expect(store.verifiedManifest, envelope);
  });

  test('cached manifest must match the current channel', () async {
    final repo = repository();
    await repo.checkForUpdate();
    store.allowCheck = false;
    expect(await repo.checkForUpdate(updateChannel: 'dev'), isNull);
    expect(requests, hasLength(2));
    expect(repo.lastCheck!.rejectReason, 'wrong_channel');
    expect(repo.lastCheck!.fromCache, isFalse);
  });

  for (final mode in [
    UpdateInstallMode.windowsInstaller,
    UpdateInstallMode.linuxDeb,
  ]) {
    test(
      'cached manifest requires an asset for current $mode and ABI',
      () async {
        await repository().checkForUpdate();
        store.allowCheck = false;
        expect(
          await repository(mode: mode, arch: 'arm64').checkForUpdate(),
          isNull,
        );
        expect(requests, hasLength(1));
      },
    );
  }

  test('cached APK must match the current Android ABI', () async {
    final assets = payload['assets']! as Map;
    assets['androidApk-arm64-v8a'] = assets.remove('androidApk');
    envelope = await sign(payload);
    expect(
      await repository(
        isAndroid: true,
        mode: UpdateInstallMode.androidApk,
        primaryAbi: 'arm64-v8a',
      ).checkForUpdate(),
      isNotNull,
    );
    store.allowCheck = false;
    expect(
      await repository(
        isAndroid: true,
        mode: UpdateInstallMode.androidApk,
        primaryAbi: 'x86_64',
      ).checkForUpdate(),
      isNull,
    );
  });

  test('cached manifest resolves a transition to Play installer', () async {
    await repository(
      isAndroid: true,
      mode: UpdateInstallMode.androidApk,
      installer: 'com.android.shell',
    ).checkForUpdate();
    store.allowCheck = false;
    final result = await repository(
      isAndroid: true,
      mode: UpdateInstallMode.androidApk,
      installer: 'com.android.vending',
    ).checkForUpdate();
    expect(result?.delivery, UpdateDelivery.storeRedirect);
    expect(result?.downloadUrl, isNull);
    expect(result?.sha256, isNull);
    expect(result?.size, isNull);
    expect(requests, hasLength(1));
  });

  test('cached stable equal-version higher build is not newer', () async {
    payload['build'] = 999;
    envelope = await sign(payload);
    final repo = repository();
    await repo.checkForUpdate();
    PackageInfo.setMockInitialValues(
      appName: 'Navis',
      packageName: 'com.navis.app.navis',
      version: '1.5.1',
      buildNumber: '43',
      buildSignature: '',
    );
    store.allowCheck = false;
    expect(await repo.checkForUpdate(), isNull);
  });

  test(
    'transport failure keeps the verified cache for a later check',
    () async {
      final repo = repository();
      await repo.checkForUpdate();
      final cached = store.verifiedManifest;
      when(
        () => dio.get<Object?>(any(), options: any(named: 'options')),
      ).thenThrow(
        DioException(requestOptions: RequestOptions(path: '/manifest.json')),
      );
      await expectLater(
        repo.checkForUpdate(forceCheck: true),
        throwsA(isA<DioException>()),
      );
      expect(store.verifiedManifest, cached);
      store.allowCheck = false;
      expect(await repo.checkForUpdate(), isNotNull);
      expect(store.recordCount, 1);
    },
  );

  test('channels are normalized and remain single URL path segments', () async {
    payload['channel'] = 'staging';
    envelope = await sign(payload);
    expect(
      await repository().checkForUpdate(updateChannel: ' STAGING '),
      isNotNull,
    );
    expect(
      urls.single,
      '${AppConstants.updateBaseUrl}channels/staging/manifest.json',
    );
    expect(UpdateRepository.channelFor(' '), 'stable');
    expect(UpdateRepository.manifestUrlFor('a/b'), contains('channels/a%2Fb/'));
  });

  for (final channel in ['dev', 'staging', 'stable']) {
    for (final build in <int?>[43, 42, 41, null]) {
      test('$channel same semver with build $build', () async {
        payload['channel'] = channel;
        payload['version'] = '1.5.0-dev+999';
        if (build != null) payload['build'] = build;
        envelope = await sign(payload);
        final repo = repository(mode: UpdateInstallMode.androidApk);
        final result = await repo.checkForUpdate(updateChannel: channel);
        if (channel != 'stable' && build == 43) {
          expect(result, isNotNull);
          expect(result!.downloadUrl, _assetUrl);
          expect(result.version, '1.5.0-dev+999');
          expect(result.buildNumber, 43);
          expect(result.notificationKey, '1.5.0-dev+999+43');
        } else {
          expect(result, isNull);
          expect(repo.lastCheck!.rejectReason, 'version_not_newer');
        }
      });
    }

    for (final version in ['1.4.9', '1.5.1']) {
      for (final build in <int?>[1, 999, null]) {
        test(
          '$channel semver $version takes priority over build $build',
          () async {
            payload['channel'] = channel;
            payload['version'] = version;
            if (build != null) payload['build'] = build;
            envelope = await sign(payload);
            final result = await repository().checkForUpdate(
              updateChannel: channel,
            );
            expect(result, version == '1.5.1' ? isNotNull : isNull);
          },
        );
      }
    }
  }

  for (final build in <Object>['43', 43.5, -1]) {
    test('invalid signed build $build is rejected', () async {
      payload['build'] = build;
      envelope = await sign(payload);
      final repo = repository();
      expect(await repo.checkForUpdate(), isNull);
      expect(repo.lastCheck!.rejectReason, 'malformed_payload');
    });
  }

  test(
    'non-numeric running build cannot offer an equal-version update',
    () async {
      PackageInfo.setMockInitialValues(
        appName: 'Navis Dev',
        packageName: 'com.navis.app.navis.dev',
        version: '1.5.0',
        buildNumber: 'unknown',
        buildSignature: '',
      );
      payload.addAll({'channel': 'dev', 'version': '1.5.0', 'build': 43});
      envelope = await sign(payload);
      expect(await repository().checkForUpdate(updateChannel: 'dev'), isNull);
    },
  );

  test('bad signature is rejected before payload parsing', () async {
    envelope = {
      ...envelope! as Map,
      'signature': base64Encode(List.filled(64, 0)),
    };
    final repo = repository();
    expect(await repo.checkForUpdate(), isNull);
    expect(repo.lastCheck!.signatureValid, isFalse);
    expect(repo.lastCheck!.payloadVersion, isNull);
    expect(repo.lastCheck!.rejectReason, 'invalid_signature');
    expect(store.recordCount, 1);
  });

  test('manifest signed by another key is rejected', () async {
    envelope = await sign(payload, key: await ed25519.newKeyPair());
    final repo = repository();
    expect(await repo.checkForUpdate(), isNull);
    expect(repo.lastCheck!.rejectReason, 'invalid_signature');
  });

  test('tampering with signed payload bytes invalidates signature', () async {
    final signed = envelope! as Map<String, String>;
    final bytes = base64Decode(signed['payload']!);
    bytes[0] ^= 1;
    envelope = {...signed, 'payload': base64Encode(bytes)};
    final repo = repository();
    expect(await repo.checkForUpdate(), isNull);
    expect(repo.lastCheck!.signatureValid, isFalse);
  });

  for (final (field, value, reason) in <(String, Object?, String)>[
    ('channel', 'dev', 'wrong_channel'),
    ('schema', 2, 'unsupported_schema'),
    ('version', '1.5.0', 'version_not_newer'),
    ('version', '1.4.9', 'version_not_newer'),
    ('version', '1.5.0-dev+99', 'version_not_newer'),
    ('version', 'invalid', 'invalid_version'),
    ('assets', <String, Object?>{}, 'missing_asset'),
    ('tag', null, 'malformed_payload'),
  ]) {
    test('rejects $field=$value with $reason', () async {
      payload[field] = value;
      envelope = await sign(payload);
      final repo = repository();
      expect(await repo.checkForUpdate(), isNull);
      expect(repo.lastCheck!.signatureValid, isTrue);
      expect(repo.lastCheck!.rejectReason, reason);
      expect(repo.lastCheck!.tag, isNull);
    });
  }

  for (final (field, value, reason) in <(String, Object?, String)>[
    (
      'url',
      'http://downloads.porthorion.com/navis/file.apk',
      'invalid_asset_url',
    ),
    ('url', 'https://example.com/navis/file.apk', 'invalid_asset_url'),
    (
      'url',
      'https://downloads.porthorion.com.evil/navis/file.apk',
      'invalid_asset_url',
    ),
    ('sha256', 'short', 'invalid_asset_sha256'),
    ('sha256', 'g' * 64, 'invalid_asset_sha256'),
    ('size', 0, 'invalid_asset_size'),
    ('size', -1, 'invalid_asset_size'),
    ('size', 1.5, 'invalid_asset_size'),
    ('size', '123', 'invalid_asset_size'),
  ]) {
    test('rejects invalid asset $field=$value', () async {
      ((payload['assets']! as Map)['linuxPortable'] as Map)[field] = value;
      envelope = await sign(payload);
      final repo = repository();
      expect(await repo.checkForUpdate(), isNull);
      expect(repo.lastCheck!.rejectReason, reason);
    });
  }

  test('RPM selects the matching raw uname architecture asset', () async {
    (payload['assets']! as Map)['linuxRpm-x86_64'] = {
      'url': _assetUrl,
      'sha256': _hash,
      'size': 123,
    };
    envelope = await sign(payload);
    final repo = repository(mode: UpdateInstallMode.linuxRpm);
    expect(await repo.checkForUpdate(), isNotNull);
    expect(repo.lastCheck!.assetKey, 'linuxRpm-x86_64');
  });

  test('RPM never falls back to deb or another architecture', () async {
    (payload['assets']! as Map)['linuxRpm-x86_64'] = {
      'url': _assetUrl,
      'sha256': _hash,
      'size': 123,
    };
    envelope = await sign(payload);
    final repo = repository(
      mode: UpdateInstallMode.linuxRpm,
      rpmArch: 'aarch64',
    );
    expect(await repo.checkForUpdate(), isNull);
    expect(repo.lastCheck!.assetKey, 'linuxRpm-aarch64');
    expect(repo.lastCheck!.rejectReason, 'missing_asset');
  });

  test(
    'unknown package owner retains an offer through the portable asset',
    () async {
      final repo = repository(mode: UpdateInstallMode.linuxPackageManaged);
      final result = await repo.checkForUpdate();
      expect(result, isNotNull);
      expect(result!.tagName, 'v1.5.1');
      expect(result.releaseNotes, '**Release notes**');
      expect(repo.lastCheck!.assetKey, 'linuxPortable');
    },
  );

  test('Deb selection never falls back from arm64 to amd64', () async {
    final repo = repository(mode: UpdateInstallMode.linuxDeb, arch: 'arm64');
    expect(await repo.checkForUpdate(), isNull);
    expect(repo.lastCheck!.assetKey, 'linuxDeb-arm64');
    expect(repo.lastCheck!.rejectReason, 'missing_asset');
    (payload['assets']! as Map)['linuxDeb-arm64'] = {
      'url': _assetUrl,
      'sha256': _hash,
      'size': 123,
    };
    envelope = await sign(payload);
    expect(await repo.checkForUpdate(forceCheck: true), isNotNull);
  });

  test('amd64 Deb uses the amd64 asset', () async {
    final repo = repository(mode: UpdateInstallMode.linuxDeb);
    expect(await repo.checkForUpdate(), isNotNull);
    expect(repo.lastCheck!.assetKey, 'linuxDeb-amd64');
  });

  for (final notesUrl in [
    null,
    'http://navis.porthorion.com/release',
    'https://evil.com/release',
  ]) {
    test('unsafe or absent notes URL $notesUrl uses manual download', () async {
      payload['notes_url'] = notesUrl;
      payload.remove('notes');
      envelope = await sign(payload);
      final result = await repository().checkForUpdate();
      expect(result!.htmlUrl, AppConstants.updateManualDownloadUrl);
      expect(result.releaseNotes, isNull);
    });
  }

  for (final malformed in <Object?>[
    null,
    [],
    {'payload': '%%%!', 'signature': _opensslSignature},
    {'payload': _opensslPayload},
    {
      'payload': _opensslPayload,
      'signature': base64Encode([1]),
    },
  ]) {
    test('malformed envelope $malformed returns null', () async {
      envelope = malformed;
      final repo = repository();
      expect(await repo.checkForUpdate(), isNull);
      expect(repo.lastCheck!.rejectReason, 'malformed_envelope');
    });
  }

  test(
    '404 preserves existing Dio error semantics and records failure',
    () async {
      // The former releases API did not catch Dio failures. The provider still
      // receives the transport error, while manifest validation returns null.
      when(() => dio.get<Object?>(any(), options: any(named: 'options')))
          .thenThrow(
            DioException(
              requestOptions: RequestOptions(path: '/manifest.json'),
              response: Response<void>(
                requestOptions: RequestOptions(path: '/manifest.json'),
                statusCode: 404,
              ),
              type: DioExceptionType.badResponse,
            ),
          );
      final repo = repository();
      await expectLater(repo.checkForUpdate(), throwsA(isA<DioException>()));
      expect(repo.lastCheck!.rejectReason, 'fetch_failed');
      expect(repo.lastCheck!.signatureValid, isNull);
      expect(store.recordCount, 0);
    },
  );

  test(
    'OpenSSL rawin signature verifies even with no matching asset',
    () async {
      envelope = {'payload': _opensslPayload, 'signature': _opensslSignature};
      final repo = repository(signingKey: _opensslKey);
      expect(await repo.checkForUpdate(), isNull);
      expect(repo.lastCheck!.signatureValid, isTrue);
      expect(repo.lastCheck!.payloadVersion, '9.9.9');
      expect(repo.lastCheck!.rejectReason, 'missing_asset');
    },
  );

  test('OpenSSL fixture fails verification after flipping one byte', () async {
    final bytes = base64Decode(_opensslPayload);
    bytes[0] ^= 1;
    envelope = {'payload': base64Encode(bytes), 'signature': _opensslSignature};
    final repo = repository(signingKey: _opensslKey);
    expect(await repo.checkForUpdate(), isNull);
    expect(repo.lastCheck!.signatureValid, isFalse);
    expect(repo.lastCheck!.rejectReason, 'invalid_signature');
  });
}
