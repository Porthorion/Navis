import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/constants.dart';

/// Fetches release information from the Navis Forgejo repository and compares
/// it with the installed app version to determine whether an update is
/// available.
class UpdateRepository {
  UpdateRepository({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// Returns [UpdateInfo] when a newer release exists, or `null` when the app
  /// is already up-to-date (or no releases are published yet).
  ///
  /// Pre-release builds are ignored unless [includePrerelease] is `true`.
  Future<UpdateInfo?> checkForUpdate({
    bool includePrerelease = false,
    String? updateChannel,
  }) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version; // e.g. "0.1.0"
    final currentSemver = _parseSemverCore(currentVersion);
    final resolvedChannel = (updateChannel ?? AppConstants.updateChannel)
        .trim()
        .toLowerCase();
    final allowPrerelease =
        includePrerelease || resolvedChannel != _stableUpdateChannel;

    final response = await _dio.get<List<dynamic>>(
      AppConstants.releasesApiUrl,
      options: Options(
        responseType: ResponseType.json,
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
      ),
    );

    final releases = (response.data ?? []).cast<Map<String, dynamic>>();

    final filtered =
        releases.where((r) {
          if (allowPrerelease) {
            return true;
          }
          return !(r['prerelease'] as bool? ?? false);
        }).toList()..sort((a, b) {
          final aRawTag = (a['tag_name'] as String?) ?? '';
          final bRawTag = (b['tag_name'] as String?) ?? '';
          final aSemver = _parseSemverCore(aRawTag);
          final bSemver = _parseSemverCore(bRawTag);
          if (aSemver == null && bSemver == null) return 0;
          if (aSemver == null) return 1;
          if (bSemver == null) return -1;
          // Descending, newest first.
          final semverOrder = _compareSemverCore(bSemver, aSemver);
          if (semverOrder != 0) {
            return semverOrder;
          }
          if (resolvedChannel == _devUpdateChannel) {
            final aPrerelease = a['prerelease'] as bool? ?? false;
            final bPrerelease = b['prerelease'] as bool? ?? false;
            if (aPrerelease != bPrerelease) {
              // Prefer prereleases in dev channel when semver core matches.
              return bPrerelease ? 1 : -1;
            }
          }
          return 0;
        });

    final candidate = filtered.firstWhereOrNull((r) {
      final rawTag = (r['tag_name'] as String?) ?? '';
      final tagVersion = rawTag.startsWith('v') ? rawTag.substring(1) : rawTag;
      final tagSemver = _parseSemverCore(tagVersion);

      if (currentSemver == null || tagSemver == null) {
        // Fallback when format is unexpected.
        return tagVersion != currentVersion;
      }
      return _compareSemverCore(tagSemver, currentSemver) > 0;
    });

    if (candidate == null) return null;

    final rawTag = (candidate['tag_name'] as String?) ?? '';

    // Look for an APK asset attached to the release.
    final assets = (candidate['assets'] as List<dynamic>?) ?? [];
    final preferredAssetName =
        '${_assetPrefixForChannel(resolvedChannel)}-$rawTag.apk'.toLowerCase();

    final apkAsset =
        assets.cast<Map<String, dynamic>>().firstWhereOrNull((asset) {
          final name = ((asset['name'] as String?) ?? '').toLowerCase();
          return name == preferredAssetName;
        }) ??
        assets.cast<Map<String, dynamic>>().firstWhereOrNull((asset) {
          final name = ((asset['name'] as String?) ?? '').toLowerCase();
          return name.endsWith('.apk');
        });

    final apkUrl = apkAsset?['browser_download_url'] as String?;

    return UpdateInfo(
      tagName: rawTag,
      htmlUrl: (candidate['html_url'] as String?) ?? AppConstants.repoUrl,
      releaseNotes: candidate['body'] as String?,
      apkDownloadUrl: apkUrl,
    );
  }
}

const String _stableUpdateChannel = 'stable';
const String _devUpdateChannel = 'dev';

String _assetPrefixForChannel(String channel) {
  return channel == _devUpdateChannel
      ? 'navis-dev'
      : AppConstants.updateAssetPrefix;
}

List<int>? _parseSemverCore(String raw) {
  var value = raw.trim();
  if (value.startsWith('v')) value = value.substring(1);
  final plusIndex = value.indexOf('+');
  if (plusIndex >= 0) value = value.substring(0, plusIndex);
  final dashIndex = value.indexOf('-');
  if (dashIndex >= 0) value = value.substring(0, dashIndex);

  final parts = value.split('.');
  if (parts.length < 3) return null;

  final major = int.tryParse(parts[0]);
  final minor = int.tryParse(parts[1]);
  final patch = int.tryParse(parts[2]);
  if (major == null || minor == null || patch == null) return null;
  return <int>[major, minor, patch];
}

int _compareSemverCore(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Dart 2 compatible helper — equivalent to Iterable.firstWhereOrNull
// ---------------------------------------------------------------------------
extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
