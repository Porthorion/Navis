import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/providers/app_providers.dart';

/// The mix state shared by the diagnostics API and Copy Playback Trace.
/// [read] is a `ProviderContainer.read` or `WidgetRef.read`. Holds no server
/// address, user name or token.
Map<String, Object?> mixDiagnosticsJson(
  T Function<T>(ProviderListenable<T>) read,
) {
  final session = read(recommendationSessionProvider);
  final radio = read(personalRadioProvider);
  final server = read(instantMixProvider);
  final lastFm = read(sameVibesProvider);
  return <String, Object?>{
    'appVersion': read(packageInfoProvider).asData?.value.version,
    'selectedSongMix':
        read(preferredMixModeProvider) == PreferredMixMode.legacyInstantMix
        ? 'server'
        : 'lastfm',
    'mode': session.mode?.name,
    'operationId': session.generation,
    'seedId': session.seedId,
    'stage': session.stage,
    'recommendationSource': session.source,
    'candidateCount': session.candidateCount,
    'insertedCount': session.insertedCount,
    'errorCategory': session.errorCategory,
    'retryCount': session.retryCount,
    'retryState': session.stage == 'retryPending'
        ? 'pending'
        : session.stage == 'retryExhausted'
        ? 'exhausted'
        : 'none',
    'active': radio.active || server.active || lastFm.active,
    'lastRefill': read(sameVibesProvider.notifier).lastRefill?.toJson(),
  };
}
