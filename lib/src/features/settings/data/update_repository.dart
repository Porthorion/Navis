import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:navis/src/features/integrations/domain/update_source.dart';
import 'package:navis/src/features/settings/data/update_transport.dart';
import 'package:navis/src/utils/semver.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/features/settings/data/install_source_service.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/features/settings/data/update_install_mode.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_delivery_resolver.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/constants.dart';

/// The outcome of the most recent manifest fetch, retained for diagnostics.
class UpdateCheckRecord {
  const new({
    required this.url,
    required this.timestamp,
    this.signatureValid,
    this.payloadVersion,
    this.assetKey,
    this.rejectReason,
    this.tag,
    this.fromCache = false,
  });

  final String url;
  final DateTime timestamp;
  final bool? signatureValid;
  final String? payloadVersion;
  final String? assetKey;
  final String? rejectReason;
  final String? tag;
  final bool fromCache;

  Map<String, Object?> toJson() => {
    'url': url,
    'timestamp': timestamp.toIso8601String(),
    'signatureValid': signatureValid,
    'payloadVersion': payloadVersion,
    'assetKey': assetKey,
    'rejectReason': rejectReason,
    'tag': tag,
    'fromCache': fromCache,
  };
}

/// Verifies the signed update manifest and selects the installed platform's asset.
class UpdateRepository {
  new({
    Dio? dio,
    this.source = UpdateSource.porthorion,
    InstallSourceService? installSourceService,
    UpdateCheckStore? updateCheckStore,
    this.signingPublicKey = AppConstants.updateSigningPublicKey,
    bool? isIOS,
    bool? isAndroid,
    UpdateInstallMode Function()? installModeDetector,
    String Function()? linuxDebArch,
  }) : _dio = dio ?? Dio(),
       _installSourceService = installSourceService ?? InstallSourceService(),
       _updateCheckStore = updateCheckStore ?? UpdateCheckStore(),
       _isIOS = isIOS ?? Platform.isIOS,
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _installModeDetector = installModeDetector ?? detectInstallMode,
       _debArch = linuxDebArch ?? _linuxDebArch;

  final Dio _dio;
  final UpdateSource source;
  final InstallSourceService _installSourceService;
  final UpdateCheckStore _updateCheckStore;
  final String signingPublicKey;
  final bool _isIOS;
  final bool _isAndroid;
  final UpdateInstallMode Function() _installModeDetector;
  final String Function() _debArch;
  UpdateCheckRecord? _lastCheck;

  UpdateCheckRecord? get lastCheck => _lastCheck;

  static String channelFor([String? channel]) {
    final normalized = (channel ?? AppConstants.updateChannel)
        .trim()
        .toLowerCase();
    return normalized.isEmpty ? 'stable' : normalized;
  }

  static String manifestUrlFor([
    String? channel,
    UpdateSource source = UpdateSource.porthorion,
  ]) => source.effectiveFor(channelFor(channel)) == UpdateSource.github
      ? '${AppConstants.githubReleasesBaseUrl}/latest/download/manifest.json'
      : '${AppConstants.updateBaseUrl}channels/'
            '${Uri.encodeComponent(channelFor(channel))}/manifest.json';

  /// Verifies and selects an update from a fresh or throttled cached manifest.
  ///
  /// Transport errors propagate to the existing provider error state and keep
  /// the cache. Completed fetches replace it with their verified outcome.
  Future<UpdateInfo?> checkForUpdate({
    String? updateChannel,
    bool forceCheck = false,
  }) async {
    if (_isIOS) return null;
    final channel = channelFor(updateChannel);
    final effectiveSource = source.effectiveFor(channel);
    final identity = '$channel/${effectiveSource.name}';
    final changed = await _updateCheckStore.selectSource(identity);
    if (!changed && !await _updateCheckStore.shouldCheck(force: forceCheck)) {
      final envelope = await _updateCheckStore.readVerifiedManifest();
      if (envelope == null) return null;
      return await _updateFromEnvelope(
        envelope,
        channel: channel,
        source: effectiveSource,
        fromCache: true,
      );
    }

    final url = manifestUrlFor(channel, effectiveSource);
    final timestamp = DateTime.now().toUtc();
    _lastCheck = UpdateCheckRecord(url: url, timestamp: timestamp);
    try {
      final response = await followUpdateRedirects<Object?>(
        url,
        source: effectiveSource,
        request: (url) => _dio.get<Object?>(
          url,
          options: Options(
            followRedirects: false,
            validateStatus: updateResponseStatus,
            responseType: ResponseType.json,
            receiveTimeout: const Duration(seconds: 10),
            sendTimeout: const Duration(seconds: 10),
            extra: <String, dynamic>{
              if (forceCheck) navisUserInitiatedExtraKey: true,
            },
          ),
        ),
      );
      await _updateCheckStore.recordCheck(null, identity);
      await _updateCheckStore.clearVerifiedManifest(sourceIdentity: identity);
      return await _updateFromEnvelope(
        response.data,
        channel: channel,
        source: effectiveSource,
      );
    } on Object {
      _lastCheck = UpdateCheckRecord(
        url: url,
        timestamp: timestamp,
        rejectReason: 'fetch_failed',
      );
      rethrow;
    }
  }

  Future<UpdateInfo?> _updateFromEnvelope(
    Object? data, {
    required String channel,
    required UpdateSource source,
    bool fromCache = false,
  }) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentSemver = parseSemver(
      packageInfo.version,
      allowExtraParts: true,
    );
    final url = manifestUrlFor(channel, source);
    final timestamp = DateTime.now().toUtc();
    bool? signatureValid;
    String? payloadVersion;
    String? assetKey;

    void record({String? rejectReason, String? tag}) {
      _lastCheck = UpdateCheckRecord(
        url: url,
        timestamp: timestamp,
        signatureValid: signatureValid,
        payloadVersion: payloadVersion,
        assetKey: assetKey,
        rejectReason: rejectReason,
        tag: tag,
        fromCache: fromCache,
      );
      if (rejectReason != null) {
        AppLogger.warning('Update manifest rejected: $rejectReason');
      }
    }

    UpdateInfo? reject(String reason) {
      record(rejectReason: reason);
      return null;
    }

    record();
    try {
      signatureValid = false;
      // Dio decodes JSON only when the response is labelled as JSON; accept
      // the same document when the host serves it with another content type.
      final envelope = data is String ? jsonDecode(data) : data;
      if (envelope is! Map ||
          envelope['payload'] is! String ||
          envelope['signature'] is! String) {
        return reject('malformed_envelope');
      }
      final payloadBytes = base64Decode(envelope['payload'] as String);
      final signatureBytes = base64Decode(envelope['signature'] as String);
      final keyBytes = base64Decode(signingPublicKey);
      if (signatureBytes.length != 64 || keyBytes.length != 32) {
        return reject('malformed_envelope');
      }
      signatureValid = await Ed25519().verify(
        payloadBytes,
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
        ),
      );
      if (!signatureValid) return reject('invalid_signature');

      final payload = jsonDecode(utf8.decode(payloadBytes));
      if (payload is! Map) return reject('malformed_payload');
      final version = payload['version'];
      payloadVersion = version is String ? version : null;
      if (payload['schema'] is! int || payload['schema'] != 1) {
        return reject('unsupported_schema');
      }
      if (payload['channel'] != channel) return reject('wrong_channel');
      final candidateSemver = payloadVersion == null
          ? null
          : parseSemver(payloadVersion, allowExtraParts: true);
      if (currentSemver == null || candidateSemver == null) {
        return reject('invalid_version');
      }
      final versionOrder = compareSemver(candidateSemver, currentSemver);
      final build = payload['build'];
      if (build != null && (build is! int || build < 0)) {
        return reject('malformed_payload');
      }
      final currentBuild = int.tryParse(packageInfo.buildNumber);
      final newerChannelBuild =
          (channel == 'dev' || channel == 'staging') &&
          versionOrder == 0 &&
          build is int &&
          currentBuild != null &&
          build > currentBuild;
      if (versionOrder < 0 || (versionOrder == 0 && !newerChannelBuild)) {
        return reject('version_not_newer');
      }
      final tag = payload['tag'];
      if (tag is! String ||
          tag.isEmpty ||
          (source == UpdateSource.github &&
              (!RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(tag) ||
                  tag != 'v$version')) ||
          (payload['notes'] != null && payload['notes'] is! String)) {
        return reject('malformed_payload');
      }

      final installSource = _isAndroid
          ? await _installSourceService.getInstallSource()
          : null;
      final mode = _installModeDetector();
      assetKey = mode == UpdateInstallMode.linuxDeb
          ? 'linuxDeb-${_debArch()}'
          : mode.name;
      final assets = payload['assets'];
      if (mode == UpdateInstallMode.androidApk && assets is Map) {
        final abi = installSource?.primaryAbi;
        if (const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains(abi)) {
          final splitKey = 'androidApk-$abi';
          if (assets.containsKey(splitKey)) assetKey = splitKey;
        }
      }
      final asset = assets is Map ? assets[assetKey] : null;
      if (asset is! Map) return reject('missing_asset');
      var assetUrl = asset['url'];
      final assetUri = assetUrl is String ? Uri.tryParse(assetUrl) : null;
      if (assetUrl is! String ||
          !(isUpdateAssetUrl(assetUrl, UpdateSource.porthorion) ||
              (source == UpdateSource.github &&
                  isUpdateAssetUrl(assetUrl, source))) ||
          assetUri == null) {
        return reject('invalid_asset_url');
      }
      if (source == UpdateSource.github) {
        assetUrl = '${source.assetBaseUrl}$tag/${assetUri.pathSegments.last}';
      }
      final hash = asset['sha256'];
      if (hash is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash)) {
        return reject('invalid_asset_sha256');
      }
      final size = asset['size'];
      if (size is! int || size <= 0) return reject('invalid_asset_size');

      final delivery = resolveUpdateDelivery(
        isAndroid: _isAndroid,
        selfUpdateBuildEnabled: selfUpdateBuildEnabled,
        installerPackage: installSource?.installerPackage,
      );
      final storeRedirect = delivery == UpdateDelivery.storeRedirect;
      final notesUrl = payload['notes_url'];
      final notesUri = notesUrl is String ? Uri.tryParse(notesUrl) : null;
      final htmlUrl =
          notesUri?.scheme == 'https' &&
              notesUri?.host == 'navis.porthorion.com' &&
              notesUri?.userInfo == ''
          ? notesUrl! as String
          : AppConstants.updateManualDownloadUrl;
      record(tag: tag);
      final info = UpdateInfo(
        tagName: tag,
        version: payloadVersion,
        buildNumber: build as int?,
        htmlUrl: htmlUrl,
        delivery: delivery,
        releaseNotes: payload['notes'] as String?,
        downloadUrl: storeRedirect ? null : assetUrl,
        assetFileName: storeRedirect ? null : assetUri.pathSegments.last,
        sha256: storeRedirect ? null : hash,
        size: storeRedirect ? null : size,
      );
      if (!fromCache) {
        await _updateCheckStore.recordVerifiedManifest({
          'payload': envelope['payload'] as String,
          'signature': envelope['signature'] as String,
        }, sourceIdentity: '$channel/${source.name}');
      }
      return info;
    } on FormatException {
      return reject(
        signatureValid == true ? 'malformed_payload' : 'malformed_envelope',
      );
    }
  }
}

/// Returns the Debian architecture without falling back across CPU families.
String _linuxDebArch() {
  try {
    final result = Process.runSync('uname', ['-m']);
    if (result.exitCode == 0) {
      final machine = (result.stdout as String).trim();
      if (machine == 'x86_64' || machine == 'amd64') return 'amd64';
      if (machine == 'aarch64' || machine == 'arm64') return 'arm64';
      return machine;
    }
  } on Object catch (_) {}
  return 'unknown';
}
