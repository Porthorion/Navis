import 'package:navis/src/features/settings/domain/update_delivery.dart';

/// Information about an available app update from a verified update manifest.
class UpdateInfo {
  const new({
    required this.tagName,
    this.version,
    this.buildNumber,
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

  /// The verified manifest version, when available.
  final String? version;

  /// The verified manifest build, including builds sharing a dev version.
  final int? buildNumber;

  /// The persisted identity of the update announced in Library.
  String get notificationKey => '${version ?? tagName}+${buildNumber ?? 0}';

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

  /// Serializes the verified update for the update-check store; see [fromJson].
  Map<String, Object?> toJson() => <String, Object?>{
    'tagName': tagName,
    'version': version,
    'buildNumber': buildNumber,
    'htmlUrl': htmlUrl,
    'delivery': delivery.name,
    'releaseNotes': releaseNotes,
    'downloadUrl': downloadUrl,
    'assetFileName': assetFileName,
    'sha256': sha256,
    'size': size,
  };

  /// Rebuilds a stored [UpdateInfo], or null when the stored shape is not one
  /// this app wrote. The stored JSON is local state, so nothing is trusted
  /// beyond field shapes; the caller still re-checks "newer than installed".
  static UpdateInfo? fromJson(Map<String, Object?> json) {
    UpdateDelivery? delivery;
    for (final candidate in UpdateDelivery.values) {
      if (candidate.name == json['delivery']) delivery = candidate;
    }
    final tagName = json['tagName'];
    final htmlUrl = json['htmlUrl'];
    final version = json['version'];
    final buildNumber = json['buildNumber'];
    final releaseNotes = json['releaseNotes'];
    final downloadUrl = json['downloadUrl'];
    final assetFileName = json['assetFileName'];
    final sha256 = json['sha256'];
    final size = json['size'];
    if (delivery == null ||
        tagName is! String ||
        htmlUrl is! String ||
        version is! String? ||
        buildNumber is! int? ||
        releaseNotes is! String? ||
        downloadUrl is! String? ||
        assetFileName is! String? ||
        sha256 is! String? ||
        size is! int?) {
      return null;
    }
    return UpdateInfo(
      tagName: tagName,
      version: version,
      buildNumber: buildNumber,
      htmlUrl: htmlUrl,
      delivery: delivery,
      releaseNotes: releaseNotes,
      downloadUrl: downloadUrl,
      assetFileName: assetFileName,
      sha256: sha256,
      size: size,
    );
  }
}
