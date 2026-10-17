import 'dart:async';

import 'package:navis/src/features/player/domain/playback_snapshot.dart';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/features/library/presentation/radio_station_dialogs.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// The Library Radio section.
class RadioTabContent extends ConsumerWidget {
  const new({
    super.key,
    this.scrollController,
    this.typeFilterQuery = '',
    this.onClearTypeFilter,
  });

  /// Optional external [ScrollController] so that a parent widget (e.g.
  /// `LibraryScreen`) can programmatically scroll this tab to the top.
  final ScrollController? scrollController;

  /// When non-empty, only stations whose name contains this query
  /// (case-insensitive) are shown.
  final String typeFilterQuery;

  /// Clears the enclosing Library type-to-filter query when a filtered Radio
  /// result has no matches. Standalone Radio has no type filter, so it leaves
  /// this unset and retains the ordinary empty-library state.
  final VoidCallback? onClearTypeFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final stationsAsync = ref.watch(radioStationsProvider);
    final local =
        ref.watch(localRadioStationsProvider).asData?.value ??
        const <InternetRadioStation>[];
    final isAdmin = ref.watch(serverUserIsAdminProvider).asData?.value ?? false;

    List<InternetRadioStation> filtered(List<InternetRadioStation> list) {
      if (typeFilterQuery.isEmpty) return list;
      final query = typeFilterQuery.toLowerCase();
      return list
          .where((station) => station.name.toLowerCase().contains(query))
          .toList();
    }

    Widget sections(List<InternetRadioStation>? server, {Object? error}) {
      final visibleLocal = filtered(local);
      final visibleServer = filtered(server ?? const <InternetRadioStation>[]);
      final headed = local.isNotEmpty;
      if (visibleLocal.isEmpty && visibleServer.isEmpty && error == null) {
        if (server == null && local.isEmpty) {
          return const ShimmerListPage(count: 8);
        }
        final isFilteredEmpty =
            typeFilterQuery.isNotEmpty &&
            (headed || (server?.isNotEmpty ?? false));
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: <Widget>[
            EmptyState(
              title: isFilteredEmpty
                  ? l10n.radioFilteredEmptyTitle(typeFilterQuery)
                  : l10n.radioEmptyTitle,
              subtitle: isFilteredEmpty
                  ? l10n.radioFilteredEmptySubtitle
                  : l10n.radioEmptySubtitle,
              icon: isFilteredEmpty
                  ? Icons.search_off_outlined
                  : Icons.radio_outlined,
              action: isFilteredEmpty
                  ? onClearTypeFilter == null
                        ? null
                        : FilledButton.tonalIcon(
                            style: NavisColorStyleData.tonalStyleOf(context),
                            key: const ValueKey<String>(
                              'radioClearTypeFilterAction',
                            ),
                            onPressed: onClearTypeFilter,
                            icon: const Icon(Icons.filter_alt_off_outlined),
                            label: Text(l10n.radioFilteredEmptyAction),
                          )
                  : FilledButton.tonalIcon(
                      style: NavisColorStyleData.tonalStyleOf(context),
                      key: const ValueKey<String>('radioEmptyAddAction'),
                      onPressed: () => showRadioStationEditor(context, ref),
                      icon: const Icon(Icons.add),
                      label: Text(l10n.radioAddStation),
                    ),
            ),
          ],
        );
      }
      return CustomScrollView(
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (visibleLocal.isNotEmpty)
            _stationSection(
              context,
              ref,
              visibleLocal,
              title: l10n.radioSectionDevice,
              isLocal: true,
              isAdmin: isAdmin,
            ),
          if (error != null)
            SliverToBoxAdapter(
              child: ErrorState(
                key: const ValueKey<String>('radio-server-load-error'),
                title: l10n.radioLoadErrorTitle,
                message: _radioErrorMessage(l10n, error),
                onRetry: () => ref.invalidate(radioStationsProvider),
                retryLabel: l10n.commonRetry,
              ),
            ),
          if (visibleServer.isNotEmpty)
            _stationSection(
              context,
              ref,
              visibleServer,
              title: headed ? l10n.radioSectionServer : null,
              isLocal: false,
              isAdmin: isAdmin,
            ),
          // Keeps the last row clear of the add button.
          const SliverToBoxAdapter(child: SizedBox(height: 72)),
        ],
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: RefreshIndicator(
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
              data: sections,
              loading: () => local.isEmpty
                  ? const ShimmerListPage(count: 8)
                  : sections(null),
              error: (error, _) => local.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: <Widget>[
                        ErrorState(
                          title: l10n.radioLoadErrorTitle,
                          message: _radioErrorMessage(l10n, error),
                          onRetry: () => ref.invalidate(radioStationsProvider),
                          retryLabel: l10n.commonRetry,
                        ),
                      ],
                    )
                  : sections(null, error: error),
            ),
          ),
        ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton(
            key: const ValueKey<String>('radioAddFab'),
            heroTag: 'library_radio_fab',
            onPressed: () => showRadioStationEditor(context, ref),
            tooltip: l10n.radioAddStation,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  /// One grid of stations, with an optional section [title] above it.
  /// Device stations are always editable; server stations only for admins.
  Widget _stationSection(
    BuildContext context,
    WidgetRef ref,
    List<InternetRadioStation> stations, {
    required String? title,
    required bool isLocal,
    required bool isAdmin,
  }) {
    final activeStationId = ref.watch(currentRadioStationIdProvider);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final padding = ContentLayout.padding(constraints.crossAxisExtent);
        final width = (constraints.crossAxisExtent - padding * 2).clamp(
          0.0,
          double.infinity,
        );
        if (width <= 0) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        final geometry = ContentLayout.radio(width);
        final inset = padding + (width - geometry.occupiedWidth) / 2;
        // Reserve two scaled name lines and one host line in every card.
        final painter = TextPainter(
          text: TextSpan(
            text: 'Ag\nAg',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final nameHeight = painter.height;
        painter.text = TextSpan(
          text: 'Ag',
          style: Theme.of(context).textTheme.bodySmall,
        );
        painter.layout();
        final height = (nameHeight + painter.height + 32).clamp(
          96.0,
          double.infinity,
        );
        painter.dispose();
        final grid = SliverPadding(
          padding: EdgeInsets.all(inset)
              .copyWith(top: title == null ? padding : 8, bottom: padding),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: geometry.columns,
              mainAxisExtent: height,
              crossAxisSpacing: geometry.gap,
              mainAxisSpacing: geometry.gap,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final station = stations[index];
              final playing = activeStationId == station.id;
              return _RadioStationCard(
                station: station,
                playing: playing,
                onTap: () => _onStationTap(context, ref, station, playing),
                onActions: isLocal || isAdmin
                    ? (anchor) => _showStationActions(
                        context,
                        ref,
                        station,
                        isLocal: isLocal,
                        anchor: anchor,
                      )
                    : null,
              );
            }, childCount: stations.length),
          ),
        );
        if (title == null) return grid;
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: inset,
                  end: inset,
                  top: padding,
                ),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            grid,
          ],
        );
      },
    );
  }

  Future<void> _showStationActions(
    BuildContext context,
    WidgetRef ref,
    InternetRadioStation station, {
    required bool isLocal,
    required Offset anchor,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final _StationAction? action;
    if (isDesktopRuntime) {
      action = await showDesktopContextMenu<_StationAction>(
        context: context,
        anchor: anchor,
        items: <PopupMenuEntry<_StationAction>>[
          PopupMenuItem<_StationAction>(
            value: _StationAction.edit,
            child: Text(l10n.radioEditStation),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<_StationAction>(
            value: _StationAction.delete,
            textStyle: TextStyle(color: colors.error),
            child: Text(l10n.radioDeleteStation),
          ),
        ],
      );
    } else {
      action = await showModalBottomSheet<_StationAction>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.radioEditStation),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_StationAction.edit),
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: colors.error),
                title: Text(
                  l10n.radioDeleteStation,
                  style: TextStyle(color: colors.error),
                ),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_StationAction.delete),
              ),
            ],
          ),
        ),
      );
    }
    if (!context.mounted || action == null) return;
    switch (action) {
      case _StationAction.edit:
        await showRadioStationEditor(
          context,
          ref,
          existing: station,
          isLocal: isLocal,
        );
      case _StationAction.delete:
        await showRadioStationDelete(context, ref, station, isLocal: isLocal);
    }
  }

  void _onStationTap(
    BuildContext context,
    WidgetRef ref,
    InternetRadioStation station,
    bool isPlaying,
  ) {
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
                  ? _radioErrorMessage(l10n, error)
                  : l10n.radioPlaybackError,
              level: AppNoticeLevel.error,
            );
          }),
    );
  }

  String _radioErrorMessage(AppLocalizations l10n, Object error) {
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
}

enum _StationAction { edit, delete }

class _RadioStationCard extends StatelessWidget {
  const new({
    required this.station,
    required this.playing,
    required this.onTap,
    this.onActions,
  });
  final InternetRadioStation station;
  final bool playing;
  final VoidCallback onTap;

  /// Opens Edit/Delete at the given global position; null when the user may
  /// not change this station.
  final void Function(Offset anchor)? onActions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final host = Uri.tryParse(station.streamUrl)?.host ?? '';
    final action = playing ? l10n.radioStopStation : l10n.nowPlayingPlay;
    return Semantics(
      selected: playing,
      child: Card(
        key: ValueKey('radioStation-${station.id}'),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onActions == null
              ? null
              : () {
                  final box = context.findRenderObject()! as RenderBox;
                  onActions!(box.localToGlobal(box.size.center(Offset.zero)));
                },
          onSecondaryTapDown: onActions == null
              ? null
              : (details) => onActions!(details.globalPosition),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
            child: Row(
              children: [
                Icon(
                  playing ? Icons.radio : Icons.radio_outlined,
                  color: playing ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        station.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: playing ? colors.primary : colors.onSurface,
                        ),
                      ),
                      if (playing || host.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          playing ? l10n.nowPlayingTitle : host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: IconButton(
                    tooltip: action,
                    onPressed: onTap,
                    icon: Icon(
                      playing
                          ? Icons.stop_circle_outlined
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
