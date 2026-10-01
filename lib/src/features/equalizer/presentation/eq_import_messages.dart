import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/data/eq_import_parser.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

/// The localized reason an EQ file could not be imported.
String describeEqImportError(AppLocalizations l10n, EqImportException error) {
  final line = error.line;
  return switch (error.code) {
    EqImportErrorCode.tooLarge => l10n.eqImportErrorTooLarge,
    EqImportErrorCode.empty => l10n.eqImportErrorEmpty,
    EqImportErrorCode.unreadableText => l10n.eqImportErrorUnreadable,
    EqImportErrorCode.invalidName => l10n.eqNameInvalid,
    EqImportErrorCode.invalidNavisPreset => l10n.eqImportErrorNavisPreset,
    EqImportErrorCode.unsupportedJson => l10n.eqImportErrorUnsupportedJson,
    EqImportErrorCode.unsupportedLine when line != null =>
      l10n.eqImportErrorLine(line),
    EqImportErrorCode.unsupportedLine => l10n.eqImportError,
    EqImportErrorCode.invalidValue when line != null => l10n.eqImportErrorValue(
      line,
    ),
    EqImportErrorCode.invalidValue => l10n.eqImportErrorValueNoLine,
    EqImportErrorCode.tooManyFilters => l10n.eqImportErrorTooMany(
      EqConfiguration.maximumFilters,
    ),
    EqImportErrorCode.noFilters => l10n.eqImportErrorNoFilters,
    EqImportErrorCode.invalidPreamp => l10n.eqImportErrorPreamp,
    EqImportErrorCode.fixedBandNeedsPeaking => l10n.eqImportErrorFixedBand,
    EqImportErrorCode.graphicTooFewPoints => l10n.eqImportErrorGraphic,
  };
}

/// One localized note per kind of import warning, with repeats counted.
List<String> describeEqImportWarnings(
  AppLocalizations l10n,
  List<EqImportWarning> warnings,
) {
  final counts = <EqImportWarningCode, int>{};
  EqImportWarning? graphic;
  for (final warning in warnings) {
    counts[warning.code] = (counts[warning.code] ?? 0) + 1;
    if (warning.code == EqImportWarningCode.graphicFitted) graphic = warning;
  }
  return <String>[
    for (final MapEntry(key: code, value: count) in counts.entries)
      switch (code) {
        EqImportWarningCode.preampSummed => l10n.eqImportWarningPreampSummed,
        EqImportWarningCode.preampMissing => l10n.eqImportWarningPreampMissing,
        EqImportWarningCode.instructionIgnored => l10n.eqImportWarningIgnored(
          count,
        ),
        EqImportWarningCode.filterDropped => l10n.eqImportWarningDropped(count),
        EqImportWarningCode.channelsLimited => l10n.eqImportWarningChannels,
        EqImportWarningCode.splitChannels => l10n.eqImportWarningSplitChannels,
        EqImportWarningCode.graphicFitted => _graphic(l10n, graphic!),
      },
  ];
}

String _graphic(AppLocalizations l10n, EqImportWarning warning) {
  // detail: "<filters>|<rms dB>|<max dB>".
  final parts = (warning.detail ?? '').split('|');
  final filters = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
  final rms = parts.length > 1 ? parts[1] : '?';
  return l10n.eqImportWarningGraphic(filters, rms);
}
