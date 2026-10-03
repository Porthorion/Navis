import 'package:flutter/foundation.dart';

/// Transcoded download bitrates (kbps) offered by the picker and settings.
const List<int> kDownloadBitRateOptions = <int>[320, 256, 192, 128, 96];

/// Transcode formats offered for downloads. Original files need no format.
const List<String> kDownloadFormatOptions = <String>['mp3', 'aac', 'opus'];

/// Upper bound for concurrent downloads. Each transcoded download runs its
/// own encoder on the server, so the bound protects small servers, the
/// device, and streaming bandwidth.
const int kMaxConcurrentDownloads = 4;

/// Concurrent downloads for a fresh install.
const int kDefaultConcurrentDownloads = 2;

/// Clamps a stored concurrency setting into 1..[kMaxConcurrentDownloads].
int sanitizeConcurrentDownloads(int? value) =>
    (value ?? kDefaultConcurrentDownloads).clamp(1, kMaxConcurrentDownloads);

String _formatFamily(String format) =>
    switch (format.trim().toLowerCase().replaceFirst('.', '')) {
      'm4a' || 'mp4' || 'aac' => 'aac',
      'oga' || 'ogg' => 'ogg',
      final other => other,
    };

/// Whether two audio format names denote the same encoding (an AAC stream may
/// be stored as `.m4a`).
bool sameAudioFormat(String a, String b) =>
    _formatFamily(a) == _formatFamily(b);

/// Whether a stored download is the original file: it has no forced bitrate,
/// or it has the song's own format at no less than the song's bitrate.
/// Original downloads record the song's bitrate, so a null bitrate alone does
/// not identify them.
bool isOriginalQualityDownload({
  required String format,
  required int? bitRate,
  String? songSuffix,
  int? songBitRate,
}) {
  if (bitRate == null) return true;
  final suffix = songSuffix?.trim();
  if (suffix == null || suffix.isEmpty || !sameAudioFormat(format, suffix)) {
    return false;
  }
  return songBitRate == null || bitRate >= songBitRate;
}

/// The quality one download is requested in.
@immutable
class DownloadQualityChoice {
  const new({this.quality, this.format, this.automatic = false});

  /// Null means original quality (use download.view).
  final String? quality;

  /// Null means original format.
  final String? format;

  /// True when the saved preference chose this quality without asking.
  final bool automatic;

  bool get isOriginal => quality == null && format == null;

  /// Whether this choice selects the same quality as [other], ignoring how
  /// it was chosen.
  bool sameQualityAs(DownloadQualityChoice? other) {
    if (other == null || other.quality != quality) return false;
    final mine = format;
    final theirs = other.format;
    if (mine == null || theirs == null) return mine == theirs;
    return sameAudioFormat(mine, theirs);
  }
}

/// How downloads pick their quality.
enum DownloadQualityMode {
  /// Show the quality picker for every download.
  ask,

  /// Always download the original file.
  original,

  /// Always transcode to the saved bitrate and format.
  transcode;

  static DownloadQualityMode parse(String? value) => switch (value) {
    'original' => DownloadQualityMode.original,
    'transcode' => DownloadQualityMode.transcode,
    _ => DownloadQualityMode.ask,
  };
}

/// The saved download quality preference.
@immutable
class DownloadQualityPreference {
  const new({
    this.mode = DownloadQualityMode.ask,
    this.bitRate = 320,
    this.format = 'mp3',
    this.prompted = false,
  });

  /// Builds a preference from stored values, falling back to defaults for
  /// anything unknown so a bad row never blocks downloads.
  factory fromStored({
    String? mode,
    int? bitRate,
    String? format,
    bool? prompted,
  }) {
    final normalizedFormat = format?.trim().toLowerCase();
    return DownloadQualityPreference(
      mode: DownloadQualityMode.parse(mode),
      bitRate: kDownloadBitRateOptions.contains(bitRate) ? bitRate! : 320,
      format: kDownloadFormatOptions.contains(normalizedFormat)
          ? normalizedFormat!
          : 'mp3',
      prompted: prompted ?? false,
    );
  }

  final DownloadQualityMode mode;

  /// Bitrate (kbps) used when [mode] is [DownloadQualityMode.transcode].
  final int bitRate;

  /// Transcode format, used by the picker and by [DownloadQualityMode.transcode].
  final String format;

  /// Whether the one-time "always download in this quality?" prompt was
  /// answered.
  final bool prompted;

  /// The saved choice, or null when downloads should ask.
  DownloadQualityChoice? get savedChoice => switch (mode) {
    DownloadQualityMode.ask => null,
    DownloadQualityMode.original => const DownloadQualityChoice(
      automatic: true,
    ),
    DownloadQualityMode.transcode => DownloadQualityChoice(
      quality: '$bitRate',
      format: format,
      automatic: true,
    ),
  };

  /// The preference that always downloads in [choice].
  static ({DownloadQualityMode mode, int? bitRate, String? format}) fromChoice(
    DownloadQualityChoice choice,
  ) {
    if (choice.isOriginal) {
      return (mode: DownloadQualityMode.original, bitRate: null, format: null);
    }
    return (
      mode: DownloadQualityMode.transcode,
      bitRate: int.tryParse(choice.quality ?? ''),
      format: choice.format?.toLowerCase(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadQualityPreference &&
      other.mode == mode &&
      other.bitRate == bitRate &&
      other.format == format &&
      other.prompted == prompted;

  @override
  int get hashCode => Object.hash(mode, bitRate, format, prompted);
}
