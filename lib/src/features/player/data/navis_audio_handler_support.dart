part of 'navis_audio_handler.dart';

bool get _isAndroidRuntime => !kIsWeb && Platform.isAndroid;

bool get _isWindowsRuntime => !kIsWeb && Platform.isWindows;

bool get _isLinuxRuntime => !kIsWeb && Platform.isLinux;

bool get _isDesktopRuntime =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

bool get _supportsAudioSessionRuntime =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

class _PreparedQueueItem {
  const _PreparedQueueItem({
    required this.song,
    required this.source,
    required this.mediaItem,
    required this.audioSource,
  });

  final SongsTableData song;
  final ResolvedPlaybackSource source;
  final MediaItem mediaItem;
  final AudioSource audioSource;
}

class CrossfadeTransitionMetric {
  const CrossfadeTransitionMetric({
    required this.transitionId,
    required this.targetIndex,
    required this.phase,
    required this.platform,
    required this.backend,
    required this.fadeDurationMs,
    this.sourceKind,
    this.format,
    this.sampleRate,
    this.prewarmLatencyMs,
    this.fadeElapsedMs,
    this.swapLatencyMs,
    this.fallbackReason,
    this.canceledReason,
  });

  final int transitionId;
  final int? targetIndex;
  final String phase;
  final String platform;
  final String backend;
  final String? sourceKind;
  final String? format;
  final int? sampleRate;
  final int? prewarmLatencyMs;
  final int fadeDurationMs;
  final int? fadeElapsedMs;
  final int? swapLatencyMs;
  final String? fallbackReason;
  final String? canceledReason;

  String toDebugString() {
    final fields = <String, Object?>{
      'transitionId': transitionId,
      'targetIndex': targetIndex,
      'phase': phase,
      'platform': platform,
      'backend': backend,
      'sourceKind': sourceKind,
      'format': format,
      'sampleRate': sampleRate,
      'prewarmLatencyMs': prewarmLatencyMs,
      'fadeDurationMs': fadeDurationMs,
      'fadeElapsedMs': fadeElapsedMs,
      'swapLatencyMs': swapLatencyMs,
      'fallbackReason': fallbackReason,
      'canceledReason': canceledReason,
    };
    return fields.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
  }
}
