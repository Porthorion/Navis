import 'package:navis/src/features/settings/domain/update_delivery.dart';

/// Information about an available app update from a verified update manifest.
class UpdateInfo {
  const new({
    required this.tagName,
    required this.htmlUrl,
    required this.delivery,
    required this.sha256,
    required this.size,
    this.releaseNotes,
    this.downloadUrl,
    this.assetFileName,
  });

  /// The release tag, e.g. `v0.2.0`.
  final String tagName;

  /// URL to the release notes or manual download page.
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

  /// Expected SHA-256 digest; omitted only for store redirects.
  final String? sha256;

  /// Expected artifact size in bytes; omitted only for store redirects.
  final int? size;

  /// The filename of the asset at [downloadUrl], e.g.
  /// `navis-v1.2.0-linux-amd64.deb`.
  final String? assetFileName;
}
