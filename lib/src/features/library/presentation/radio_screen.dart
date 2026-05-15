import 'dart:async';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/providers/app_providers.dart';

class RadioScreen extends ConsumerWidget {
  const RadioScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.radioTitle)),
      body: const RadioTabContent(),
    );
  }
}

class RadioTabContent extends ConsumerWidget {
  const RadioTabContent({
    super.key,
    this.scrollController,
    this.typeFilterQuery = '',
  });

  /// Optional external [ScrollController] so that a parent widget (e.g.
  /// `LibraryScreen`) can programmatically scroll this tab to the top.
  final ScrollController? scrollController;

  /// When non-empty, only stations whose name contains this query
  /// (case-insensitive) are shown.
  final String typeFilterQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final stationsAsync = ref.watch(radioStationsProvider);
    final activeStationId = ref.watch(currentRadioStationIdProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(radioStationsProvider);
        try {
          await ref.read(radioStationsProvider.future);
        } on Object {
          // RefreshIndicator should remain usable even if server radio
          // endpoints are unavailable.
        }
      },
      child: stationsAsync.when(
        data: (stations) {
          if (typeFilterQuery.isNotEmpty) {
            final query = typeFilterQuery.toLowerCase();
            stations = stations
                .where(
                  (s) => s.name.toLowerCase().contains(query),
                )
                .toList();
          }
          if (stations.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: <Widget>[
                EmptyState(
                  title: l10n.radioEmptyTitle,
                  subtitle: l10n.radioEmptySubtitle,
                  icon: Icons.radio_outlined,
                ),
              ],
            );
          }
          return ListView.separated(
            controller: scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: stations.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final station = stations[index];
              final isPlaying = activeStationId == station.id;
              return ListTile(
                leading: Icon(
                  isPlaying ? Icons.radio : Icons.radio_outlined,
                  color: isPlaying
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(
                  station.name,
                  style: isPlaying
                      ? TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        )
                      : null,
                ),
                subtitle: Text(
                  station.streamUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: isPlaying
                    ? IconButton(
                        icon: const Icon(Icons.stop_circle_outlined),
                        tooltip: l10n.radioStopStation,
                        onPressed: () {
                          final handler = ref.read(audioHandlerProvider);
                          unawaited(handler?.stopRadio());
                        },
                      )
                    : null,
                onTap: () => _onStationTap(context, ref, station, isPlaying),
              );
            },
          );
        },
        loading: () => const ShimmerListPage(count: 8),
        error: (error, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: <Widget>[
            ErrorState(
              title: l10n.radioLoadErrorTitle,
              message: _radioErrorMessage(l10n, error),
              onRetry: () => ref.invalidate(radioStationsProvider),
              retryLabel: l10n.commonRetry,
            ),
          ],
        ),
      ),
    );
  }

  void _onStationTap(
    BuildContext context,
    WidgetRef ref,
    dynamic station,
    bool isPlaying,
  ) {
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) return;

    if (isPlaying) {
      unawaited(handler.stopRadio());
      return;
    }

    unawaited(
      handler
          .playRadioStream(
            stationId: station.id as String,
            stationName: station.name as String,
            streamUrl: station.streamUrl as String,
            homePageUrl: station.homePageUrl as String?,
          )
          .catchError((Object error) {
            if (!context.mounted) return;
            final l10n = AppLocalizations.of(context)!;
            showAppNotice(
              context,
              message: l10n.radioPlaybackError,
              level: AppNoticeLevel.error,
            );
          }),
    );
  }

  String _radioErrorMessage(AppLocalizations l10n, Object error) {
    if (error is SubsonicNotFoundException) {
      return l10n.radioUnsupportedMessage;
    }
    if (error is SubsonicGenericException &&
        (error.code == 404 || error.code == 501)) {
      return l10n.radioUnsupportedMessage;
    }
    return error.toString();
  }
}
