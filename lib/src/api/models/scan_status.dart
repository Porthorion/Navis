/// Typed view of the OpenSubsonic `getScanStatus` response.
///
/// `scanning` and `count` are part of the standard endpoint contract. Servers
/// may add provider-specific fields; Navidrome's `lastScan` is read when
/// present so a completed-scan token can be observed without extra probing.
/// Missing optional fields never fail the parse.
class ScanStatus {
  const ScanStatus({required this.scanning, this.count, this.lastScan});

  factory ScanStatus.fromJson(Map<String, dynamic> json) {
    return ScanStatus(
      scanning: json['scanning'] == true,
      count: (json['count'] as num?)?.toInt(),
      lastScan:
          json['lastScan'] is String && (json['lastScan'] as String).isNotEmpty
          ? DateTime.tryParse(json['lastScan'] as String)
          : null,
    );
  }

  final bool scanning;
  final int? count;

  /// Provider scan identity (Navidrome supplies an ISO-8601 timestamp).
  final DateTime? lastScan;
}
