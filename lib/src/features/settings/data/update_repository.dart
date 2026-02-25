import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:navis/src/features/settings/domain/update_info.dart';

/// Fetches release information from the Navis Forgejo repository and compares
/// it with the installed app version to determine whether an update is
/// available.
class UpdateRepository {
  UpdateRepository({Dio? dio}) : _dio = dio ?? Dio();

  static const _releasesUrl =
      'https://git.porthorion.com/api/v1/repos/khalifa/Navis/releases';

  final Dio _dio;

  /// Returns [UpdateInfo] when a newer release exists, or `null` when the app
  /// is already up-to-date (or no releases are published yet).
  ///
  /// Pre-release builds are ignored unless [includePrerelease] is `true`.
  Future<UpdateInfo?> checkForUpdate({bool includePrerelease = false}) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version; // e.g. "0.1.0"

    final response = await _dio.get<List<dynamic>>(
      _releasesUrl,
      options: Options(
        responseType: ResponseType.json,
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
      ),
    );

    final releases = (response.data ?? []).cast<Map<String, dynamic>>();

    // Find the first release that matches the prerelease filter.
    final candidate = releases.firstWhereOrNull(
      (r) => includePrerelease || !(r['prerelease'] as bool? ?? false),
    );

    if (candidate == null) return null;

    final rawTag = (candidate['tag_name'] as String?) ?? '';
    // Strip leading 'v' so we can compare semver strings directly.
    final tagVersion = rawTag.startsWith('v') ? rawTag.substring(1) : rawTag;

    if (tagVersion == currentVersion) return null;

    return UpdateInfo(
      tagName: rawTag,
      htmlUrl: (candidate['html_url'] as String?) ?? _releasesUrl,
      releaseNotes: candidate['body'] as String?,
    );
  }
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
