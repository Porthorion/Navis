import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
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
  const RadioTabContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final stationsAsync = ref.watch(radioStationsProvider);

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
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: stations.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final station = stations[index];
              return ListTile(
                leading: const Icon(Icons.radio_outlined),
                title: Text(station.name),
                subtitle: Text(
                  station.streamUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
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
