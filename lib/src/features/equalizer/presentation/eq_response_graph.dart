import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';

/// Read-only response previews use the same rendering as the main graph editor.
class EqResponseGraph extends StatelessWidget {
  const EqResponseGraph({
    required this.configuration,
    this.sampleRate = 48000,
    this.compact = false,
    this.selectedBand,
    super.key,
  });
  final EqConfiguration configuration;
  final double sampleRate;
  final bool compact;
  final int? selectedBand;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      label: l10n.eqResponse,
      value:
          '${configuration.filters.length} filters, ${configuration.preampDb} dB preamp',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.eqFilterResponse,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: compact ? 84 : 180,
            child: EqGraphEditor(
              configuration: configuration,
              selectedBand: selectedBand,
              sampleRate: sampleRate,
              enabled: false,
              readOnly: true,
              compact: true,
              onSelect: (_) {},
              onBegin: () {},
              onChanged: (_) {},
              onCommit: () {},
              onCancel: () {},
              onPreampInput: () {},
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 8),
            Text(
              l10n.eqGraphDescription,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
