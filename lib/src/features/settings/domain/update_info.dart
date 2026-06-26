import 'package:navis/src/features/settings/domain/update_delivery.dart';

/// Information about an available app update fetched from the Forgejo releases API.
class UpdateInfo {
  const UpdateInfo({
    required this.tagName,
    required this.htmlUrl,
    required this.delivery,
    this.releaseNotes,
    this.downloadUrl,
    this.assetFileName,
  });

  /// The release tag, e.g. `v0.2.0`.
  final String tagName;

  /// URL to the Forgejo release page for this tag.
  final String htmlUrl;

  /// How the update should be presented and applied.
  final UpdateDelivery delivery;

  /// Optional release notes / changelog body.
  final String? releaseNotes;

  /// Direct download URL for the platform-appropriate release artifact.
  ///
  /// Omitted for store redirects. On Android this is the APK; on desktop it is
  /// the zip / tar.gz / deb / exe asset for the current install mode.
  final String? downloadUrl;

  /// The filename of the asset at [downloadUrl], e.g.
  /// `navis-v1.2.0-linux-amd64.deb`.
  final String? assetFileName;

  /// Convenience getter — Android callers that previously used [apkDownloadUrl]
  /// can continue to do so without changes.
  String? get apkDownloadUrl => downloadUrl;
}
