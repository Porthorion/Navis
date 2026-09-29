import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/routing/navigation_service.dart';

/// Shared navigation entry, disabled when the actual backend lacks EQ.
class EqualizerEntry extends ConsumerWidget {
  const EqualizerEntry({this.onOpen, super.key});
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final supported = ref.watch(eqCapabilitiesProvider).supported;
    final preset = supported
        ? ref.watch(equalizerProvider).asData?.value.displayName(l10n.eqCustom)
        : null;
    return ListTile(
      key: const ValueKey('equalizerEntryPoint'),
      leading: const Icon(Icons.equalizer),
      title: Text(l10n.eqTitle),
      subtitle: Text(
        supported ? preset ?? l10n.eqSubtitle : l10n.eqUnavailable,
      ),
      enabled: supported,
      trailing: const Icon(Icons.chevron_right),
      onTap: supported
          ? () {
              onOpen?.call();
              // Collapses player overlays so the page is not hidden behind
              // an expanded Now Playing sheet.
              NavService.openEqualizer(context, ref);
            }
          : null,
    );
  }
}
