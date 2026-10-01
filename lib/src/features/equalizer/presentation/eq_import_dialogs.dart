import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/presentation/eq_import_messages.dart';
import 'package:navis/src/features/equalizer/data/autoeq_catalogue.dart';
import 'package:navis/src/features/equalizer/data/eq_import_parser.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_band_inspector.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_painter.dart';
import 'package:navis/src/features/equalizer/presentation/eq_response_graph.dart';

class EqNameDialog extends StatefulWidget {
  const new({required this.initial, super.key});
  final String initial;
  @override
  State<EqNameDialog> createState() => _EqNameDialogState();
}

class _EqNameDialogState extends State<EqNameDialog> {
  late final input = TextEditingController(text: widget.initial);
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    void save() {
      if (form.currentState!.validate()) {
        Navigator.pop(context, input.text.trim());
      }
    }

    return AlertDialog(
      title: Text(l10n.eqName),
      content: Form(
        key: form,
        child: TextFormField(
          controller: input,
          autofocus: true,
          maxLength: 120,
          validator: (s) =>
              s == null || s.trim().isEmpty ? l10n.eqNameInvalid : null,
          onFieldSubmitted: (_) => save(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.eqCancel),
        ),
        FilledButton(onPressed: save, child: Text(l10n.eqSave)),
      ],
    );
  }
}

class EqPasteDialog extends StatefulWidget {
  const new({super.key});
  @override
  State<EqPasteDialog> createState() => _EqPasteDialogState();
}

class _EqPasteDialogState extends State<EqPasteDialog> {
  final text = TextEditingController();
  bool fixed = false;
  String? error;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.eqImportPaste),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.eqImportText),
              const SizedBox(height: 16),
              TextField(
                controller: text,
                minLines: 5,
                maxLines: 10,
                maxLength: EqImportParser.maximumBytes,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(errorText: error),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.eqFixedImport),
                value: fixed,
                onChanged: (value) => setState(() => fixed = value!),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.eqCancel),
        ),
        FilledButton(
          onPressed: () {
            try {
              Navigator.pop(
                context,
                EqImportParser().parseText(
                  text.text,
                  id: 'preview',
                  name: l10n.eqImportDefaultName,
                  // Unchecked lets the contents decide.
                  fixedBand: fixed ? true : null,
                ),
              );
            } on EqImportException catch (e) {
              setState(() => error = describeEqImportError(l10n, e));
            }
          },
          child: Text(l10n.eqImportPreview),
        ),
      ],
    );
  }
}

/// Returns `(name, enable)` when the user saves the reviewed preset.
class EqImportPreviewDialog extends StatefulWidget {
  const new({
    required this.preset,
    required this.name,
    this.warnings = const <EqImportWarning>[],
    super.key,
  });
  final EqPreset preset;
  final String name;

  /// What the import could not reproduce exactly.
  final List<EqImportWarning> warnings;
  @override
  State<EqImportPreviewDialog> createState() => _EqImportPreviewDialogState();
}

class _EqImportPreviewDialogState extends State<EqImportPreviewDialog> {
  late final name = TextEditingController(text: widget.name);
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final preset = widget.preset;
    final configuration = preset.configuration;
    final source = preset.source;
    void save({required bool enabled}) {
      if (form.currentState!.validate()) {
        Navigator.pop(context, (name.text.trim(), enabled));
      }
    }

    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      title: Text(l10n.eqImportPreview),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.eqPreviewDescription, style: muted),
                const SizedBox(height: 16),
                TextFormField(
                  controller: name,
                  maxLength: 120,
                  decoration: InputDecoration(labelText: l10n.eqName),
                  validator: (s) =>
                      s == null || s.trim().isEmpty ? l10n.eqNameInvalid : null,
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Chip(label: Text(eqModeLabel(l10n, configuration.mode))),
                    Chip(
                      label: Text(
                        l10n.eqFilterCount(configuration.filters.length),
                      ),
                    ),
                    Chip(
                      label: Text(
                        '${l10n.eqPreamp} ${eqSignedGain(configuration.preampDb)} dB',
                      ),
                    ),
                  ],
                ),
                if (source?.measurementSource != null ||
                    source?.target != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    [
                      ?source!.measurementSource,
                      if (source.target != null)
                        '${l10n.eqTarget}: ${source.target}',
                    ].join(' · '),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
                if (source?.url != null)
                  SelectableText(source!.url!, style: muted),
                if (source?.revision != null)
                  SelectableText(source!.revision!, style: muted),
                if (widget.warnings.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.eqImportWarningsTitle,
                    style: theme.textTheme.titleSmall,
                  ),
                  for (final note in describeEqImportWarnings(
                    l10n,
                    widget.warnings,
                  ))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(note, style: theme.textTheme.bodyMedium),
                    ),
                ],
                const SizedBox(height: 16),
                EqResponseGraph(configuration: configuration),
                const SizedBox(height: 16),
                _FilterTable(filters: configuration.filters),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.eqCancel),
        ),
        OutlinedButton(
          onPressed: () => save(enabled: false),
          child: Text(l10n.eqSave),
        ),
        FilledButton(
          onPressed: () => save(enabled: true),
          child: Text(l10n.eqSaveEnable),
        ),
      ],
    );
  }
}

/// A readable list of every imported filter, in authored order.
class _FilterTable extends StatelessWidget {
  const new({required this.filters});
  final List<EqFilter> filters;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final numbers = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < filters.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Opacity(
              opacity: filters[i].enabled ? 1 : .6,
              child: Row(
                children: [
                  SizedBox(width: 28, child: Text('${i + 1}', style: numbers)),
                  Expanded(
                    flex: 3,
                    child: Text(
                      eqFilterTypeLabel(l10n, filters[i].type),
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      '${eqNumber(filters[i].frequencyHz)} Hz',
                      style: numbers,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      filters[i].usesGain
                          ? '${eqSignedGain(filters[i].gainDb)} dB'
                          : '—',
                      style: numbers,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'Q ${eqNumber(filters[i].q, decimals: 3)}',
                      style: numbers,
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      filters[i].enabled
                          ? l10n.eqFilterOn
                          : l10n.eqFilterOffShort,
                      style: numbers,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class EqAutoEqDialog extends ConsumerStatefulWidget {
  const new({super.key});
  @override
  ConsumerState<EqAutoEqDialog> createState() => _EqAutoEqDialogState();
}

class _EqAutoEqDialogState extends ConsumerState<EqAutoEqDialog> {
  late final catalogue = ref.read(autoEqCatalogueProvider);
  AutoEqIndex? index;
  String query = '';
  bool recommended = true;
  bool busy = true;
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool refresh = false}) async {
    final current = ++generation;
    try {
      final next = await (refresh ? catalogue.refresh() : catalogue.load());
      if (mounted && current == generation) {
        setState(() {
          index = next;
          error = null;
        });
      }
    } on Object {
      if (mounted && current == generation) {
        setState(() => error = AppLocalizations.of(context)!.eqRefreshError);
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  Future<void> _download(AutoEqEntry entry) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final preset = await catalogue.download(index!, entry);
      if (mounted) Navigator.pop(context, preset);
    } on Object {
      if (mounted) {
        setState(() {
          busy = false;
          error = AppLocalizations.of(context)!.eqDownloadError;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final results = index?.search(query, recommendedOnly: recommended) ?? [];
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.eqAutoEq),
      content: SizedBox(
        width: 680,
        height: 520,
        child: ListView(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.eqSearch,
                helperText: l10n.eqAutoEqHint,
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.eqRecommendedOnly),
              value: recommended,
              onChanged: busy
                  ? null
                  : (value) => setState(() => recommended = value!),
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (results.isEmpty && !busy)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.eqNoResults),
              )
            else if (index != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(l10n.eqResultCount(results.length), style: small),
              ),
            for (final entry in results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.headphones_outlined),
                title: Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  entry.recommended
                      ? '${entry.measurementSource} · ${l10n.eqRecommended}'
                      : entry.measurementSource,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.file_download_outlined),
                onTap: busy ? null : () => unawaited(_download(entry)),
              ),
            const SizedBox(height: 8),
            Text(l10n.eqCatalogueOffline, style: small),
            Text(l10n.eqAttribution, style: small),
            if (index != null)
              Text(
                l10n.eqCatalogueRevision(index!.revision.substring(0, 12)),
                style: small,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.eqCancel),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () {
                  setState(() => busy = true);
                  unawaited(_load(refresh: true));
                },
          child: Text(l10n.eqRefreshCatalogue),
        ),
      ],
    );
  }
}
