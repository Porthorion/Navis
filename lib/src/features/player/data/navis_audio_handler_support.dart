part of 'navis_audio_handler.dart';

bool get _isAndroidRuntime => !kIsWeb && Platform.isAndroid;

bool get _isWindowsRuntime => !kIsWeb && Platform.isWindows;

bool get _isLinuxRuntime => !kIsWeb && Platform.isLinux;

bool get _isDesktopRuntime =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

bool get _supportsAudioSessionRuntime =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

class _PreparedQueueItem {
  const new({
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
  const new({
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

/// Time limits for native player work. Tests shorten them to exercise
/// recovery without waiting for production timeouts.
@immutable
class NavisPlaybackTimeouts {
  const new({
    this.load = const Duration(seconds: 12),
    this.remoteStall = const Duration(seconds: 12),
    this.seekBufferingRecovery = const Duration(seconds: 3),
    this.reset = const Duration(seconds: 4),
    this.control = const Duration(seconds: 4),
    this.seekProgress = const Duration(seconds: 45),
    this.remoteLoad = const Duration(seconds: 45),
    this.focusRetry = const Duration(minutes: 2),
    this.radioRecovery = const Duration(minutes: 10),
    this.radioHealthyPlay = const Duration(minutes: 1),
  });

  /// A native load or queue mutation that takes longer is abandoned and the
  /// players are rebuilt.
  final Duration load;

  /// A remote stream that stops making progress for this long is recovered.
  final Duration remoteStall;
  final Duration seekBufferingRecovery;

  /// Stopping, disposing or reconfiguring a player during recovery.
  final Duration reset;

  /// A single transport control call.
  final Duration control;

  /// How long a seek may keep waiting past [load] while the song's cache
  /// download is still receiving bytes: on a slow link a far seek in a large
  /// file legitimately takes longer, and reloading would start it over.
  final Duration seekProgress;

  /// Loading a remote (external) song that is not cached. The server fetches
  /// the whole file before it answers, which routinely takes longer than
  /// [load] on a first play.
  final Duration remoteLoad;

  /// How long a denied Play keeps asking for audio focus before it stays
  /// paused.
  final Duration focusRetry;

  /// How long a station keeps reconnecting after transient failures.
  final Duration radioRecovery;

  /// How long a reconnected station must play before its next failure starts
  /// a fresh [radioRecovery] budget.
  final Duration radioHealthyPlay;
}

/// A request belongs to the selected queue occurrence, independent of whether
/// the native player is temporarily paused while loading or recovering.
class _PendingSeek {
  new({
    required this.generation,
    required this.songId,
    required this.queueIndex,
    required this.position,
  });

  final int generation;
  final String songId;
  int? queueIndex;
  final Duration position;
  String stage = 'waiting for source';
  String? outcome;
  int recoveryAttempts = 0;

  /// Set when the seek was served by reopening the transcode at an offset.
  String? path;

  /// Why each settlement probe that did not confirm the seek gave up, for
  /// diagnostics: the rule that ended it and the state it saw.
  final List<Map<String, Object?>> unsettled = <Map<String, Object?>>[];
}
