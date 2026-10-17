import 'package:dio/dio.dart';
import 'package:navis/src/features/integrations/domain/update_source.dart';
import 'package:navis/src/utils/constants.dart';

/// Checks both the authority and path; prefix lookalikes and path traversal
/// must never expand the updater's trust boundary.
bool isUpdateUrlUnder(String url, String base) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      !uri.hasFragment &&
      url.startsWith(base) &&
      uri.toString().startsWith(base) &&
      !uri.pathSegments.any(
        (part) =>
            part == '..' ||
            part == '.' ||
            part.contains('/') ||
            part.contains(r'\'),
      );
}

bool isUpdateAssetUrl(String url, UpdateSource source) {
  if (!isUpdateUrlUnder(url, source.assetBaseUrl)) return false;
  final uri = Uri.parse(url);
  return !uri.hasQuery &&
      uri.pathSegments.isNotEmpty &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(uri.pathSegments.last);
}

/// Dio's automatic redirects bypass interceptors. Follow each hop explicitly
/// so policy and destination checks run before every network request.
Future<Response<T>> followUpdateRedirects<T>(
  String url, {
  required UpdateSource source,
  required Future<Response<T>> Function(String url) request,
}) async {
  var current = url;
  for (var hop = 0; hop <= 5; hop++) {
    final uri = Uri.tryParse(current);
    final githubAssetHost =
        source == UpdateSource.github &&
        uri != null &&
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.port == 443 &&
        !uri.hasFragment &&
        const {
          'objects.githubusercontent.com',
          'release-assets.githubusercontent.com',
        }.contains(uri.host);
    final githubRelease =
        source == UpdateSource.github &&
        (isUpdateUrlUnder(
              current,
              '${AppConstants.githubReleasesBaseUrl}/download/',
            ) ||
            current ==
                '${AppConstants.githubReleasesBaseUrl}/latest/download/manifest.json');
    final allowed = source == UpdateSource.porthorion
        ? isUpdateUrlUnder(current, AppConstants.updateBaseUrl)
        : githubRelease || (hop > 0 && githubAssetHost);
    if (!allowed) {
      throw _redirectError(
        current,
        'Update redirect is outside the selected source',
      );
    }
    final response = await request(current);
    if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
      return response;
    }
    final location = response.headers.value('location');
    if (location == null || hop == 5) {
      throw _redirectError(current, 'Invalid or excessive update redirects');
    }
    current = Uri.parse(current).resolve(location).toString();
  }
  throw _redirectError(current, 'Excessive update redirects');
}

bool updateResponseStatus(int? status) =>
    status != null &&
    ((status >= 200 && status < 300) ||
        const {301, 302, 303, 307, 308}.contains(status));

DioException _redirectError(String url, String message) => DioException(
  requestOptions: RequestOptions(path: url),
  message: message,
);
