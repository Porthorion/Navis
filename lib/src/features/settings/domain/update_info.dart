/// Information about an available app update fetched from the Forgejo releases API.
class UpdateInfo {
  const UpdateInfo({
    required this.tagName,
    required this.htmlUrl,
    this.releaseNotes,
  });

  /// The release tag, e.g. `v0.2.0`.
  final String tagName;

  /// URL to the Forgejo release page for this tag.
  final String htmlUrl;

  /// Optional release notes / changelog body.
  final String? releaseNotes;
}
