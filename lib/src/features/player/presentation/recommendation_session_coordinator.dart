import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

enum RecommendationMode { serverMix, sameVibes, personalRadio }

class RecommendationSession {
  const RecommendationSession({
    required this.generation,
    required this.mode,
    required this.cancelToken,
  });

  final int generation;
  final RecommendationMode mode;
  final CancelToken cancelToken;
}

class RecommendationSessionStatus {
  const RecommendationSessionStatus({
    this.generation = 0,
    this.mode,
    this.seedId,
    this.stage = 'idle',
    this.source,
    this.candidateCount = 0,
    this.insertedCount = 0,
    this.errorCategory,
    this.retryCount = 0,
  });

  final int generation;
  final RecommendationMode? mode;
  final String? seedId;
  final String stage;
  final String? source;
  final int candidateCount;
  final int insertedCount;
  final String? errorCategory;
  final int retryCount;

  RecommendationSessionStatus copyWith({
    String? stage,
    String? source,
    int? candidateCount,
    int? insertedCount,
    String? errorCategory,
    int? retryCount,
  }) => RecommendationSessionStatus(
    generation: generation,
    mode: mode,
    seedId: seedId,
    stage: stage ?? this.stage,
    source: source ?? this.source,
    candidateCount: candidateCount ?? this.candidateCount,
    insertedCount: insertedCount ?? this.insertedCount,
    errorCategory: errorCategory ?? this.errorCategory,
    retryCount: retryCount ?? this.retryCount,
  );
}

class RecommendationSessionCoordinator
    extends Notifier<RecommendationSessionStatus> {
  CancelToken? _token;

  @override
  RecommendationSessionStatus build() {
    ref.listen<int>(regularQueueReplacementEpochProvider, (previous, next) {
      stop();
    });
    ref.listen<PlaybackSnapshot>(playerStateProvider, (previous, next) {
      if (next.isRadioMode ||
          (previous != null &&
              previous.queueSongIds.isNotEmpty &&
              next.queueSongIds.isEmpty)) {
        stop();
      }
    });
    ref.listen<Object?>(
      subsonicApiProvider.select((api) => api?.connectionIdentity),
      (previous, next) {
        if (previous != next) stop();
      },
    );
    ref.onDispose(() => _token?.cancel('recommendation session disposed'));
    return const RecommendationSessionStatus();
  }

  RecommendationSession start(RecommendationMode mode, {String? seedId}) {
    _token?.cancel('recommendation session replaced');
    final token = CancelToken();
    _token = token;
    final generation = state.generation + 1;
    state = RecommendationSessionStatus(
      generation: generation,
      mode: mode,
      seedId: seedId,
      stage: 'preparing',
    );
    return RecommendationSession(
      generation: generation,
      mode: mode,
      cancelToken: token,
    );
  }

  bool owns(RecommendationSession session) =>
      state.generation == session.generation &&
      state.mode == session.mode &&
      !session.cancelToken.isCancelled;

  void report(
    RecommendationSession session, {
    String? stage,
    String? source,
    int? candidateCount,
    int? insertedCount,
    String? errorCategory,
    int? retryCount,
  }) {
    if (!owns(session)) return;
    state = state.copyWith(
      stage: stage,
      source: source,
      candidateCount: candidateCount,
      insertedCount: insertedCount,
      errorCategory: errorCategory,
      retryCount: retryCount,
    );
  }

  void stop([RecommendationSession? session]) {
    if (session != null && !owns(session)) return;
    _token?.cancel('recommendation session stopped');
    _token = null;
    state = RecommendationSessionStatus(generation: state.generation + 1);
  }
}

final recommendationSessionProvider =
    NotifierProvider<
      RecommendationSessionCoordinator,
      RecommendationSessionStatus
    >(RecommendationSessionCoordinator.new);
