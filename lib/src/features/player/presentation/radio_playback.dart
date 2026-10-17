import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Starts [station], or stops it when it is already playing. Shared by the
/// Radio screen and Search so both start stations identically.
void toggleRadioStation(
  BuildContext context,
  WidgetRef ref,
  InternetRadioStation station, {
  required bool isPlaying,
}) {
  final handler = ref.read(audioHandlerProvider);
  if (handler == null) return;

  ref.read(regularQueueReplacementEpochProvider.notifier).bump();
  if (isPlaying) {
    unawaited(handler.stopRadio());
    return;
  }

  ref.read(queueProvider.notifier).reserveSelection();
  final epoch = ref.read(regularQueueReplacementEpochProvider);
  final notices = AppNoticeScope.maybeOf(context);
  final errorMessage = AppLocalizations.of(context)!.radioPlaybackError;
  final previousFailureId = notices?.notice?.message == errorMessage
      ? notices?.notice?.id
      : null;
  bool isCurrent() =>
      context.mounted &&
      ref.read(regularQueueReplacementEpochProvider) == epoch;
  unawaited(
    handler
        .playRadioStream(
          stationId: station.id,
          stationName: station.name,
          streamUrl: station.streamUrl,
          homePageUrl: station.homePageUrl,
        )
        .then((_) {
          if (!isCurrent()) return;
          // A retry resolves this radio error, but must preserve a newer or
          // unrelated recovery notice.
          if (previousFailureId != null &&
              notices?.notice?.id == previousFailureId) {
            notices?.dismiss();
          }
        })
        .catchError((Object error) {
          if (!context.mounted || !isCurrent()) return;
          if (error is RadioPlaybackUnavailableException) return;
          final l10n = AppLocalizations.of(context)!;
          showAppNotice(
            context,
            message: error is RadioPlaybackBlockedException
                ? radioErrorMessage(l10n, error)
                : l10n.radioPlaybackError,
            level: AppNoticeLevel.error,
          );
        }),
  );
}

String radioErrorMessage(AppLocalizations l10n, Object error) {
  if (error is RadioPlaybackBlockedException) {
    return l10n.radioPlaybackBlockedOnlineServicesOff;
  }
  if (error is SubsonicNotFoundException) {
    return l10n.radioUnsupportedMessage;
  }
  if (error is SubsonicGenericException &&
      (error.code == 404 || error.code == 501)) {
    return l10n.radioUnsupportedMessage;
  }
  return l10n.commonErrorRecoveryHint;
}
