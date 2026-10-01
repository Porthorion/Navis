import 'package:flutter/foundation.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

/// The kind of file an EQ import was read as.
enum EqImportFormat {
  /// A preset exported by Navis.
  navisPreset,

  /// EasyEffects equalizer settings (JSON).
  easyEffects,

  /// Equalizer APO style filters: AutoEQ ParametricEQ, REW and APO configs.
  parametric,

  /// AutoEQ FixedBandEQ: ten peaking bands at fixed frequencies.
  fixedBand,

  /// A GraphicEQ curve (AutoEQ, Wavelet), fitted with peaking filters.
  graphic,
}

enum EqImportErrorCode {
  tooLarge,
  empty,
  unreadableText,
  invalidName,
  invalidNavisPreset,
  unsupportedJson,
  unsupportedLine,
  invalidValue,
  tooManyFilters,
  noFilters,
  invalidPreamp,
  fixedBandNeedsPeaking,
  graphicTooFewPoints,
}

/// A file that cannot be imported. [line] is 1-based when the problem is on
/// a particular line. It stays a [FormatException] so existing callers keep
/// working; the presentation layer maps [code] to a localized message.
class EqImportException extends FormatException {
  EqImportException(this.code, {this.line, this.detail})
    : super(_describe(code, line, detail));

  final EqImportErrorCode code;
  final int? line;
  final String? detail;

  static String _describe(EqImportErrorCode code, int? line, String? detail) {
    final where = line == null ? '' : ' (line $line)';
    final base = switch (code) {
      EqImportErrorCode.tooLarge => 'EQ imports must be smaller than 1 MB.',
      EqImportErrorCode.empty => 'The EQ file is empty.',
      EqImportErrorCode.unreadableText => 'The EQ file text could not be read.',
      EqImportErrorCode.invalidName =>
        'Enter a preset name of 1–120 characters.',
      EqImportErrorCode.invalidNavisPreset =>
        'Invalid or unsupported Navis EQ preset.',
      EqImportErrorCode.unsupportedJson =>
        'This JSON file is not a supported EQ format.',
      EqImportErrorCode.unsupportedLine => 'Unsupported EQ instruction',
      EqImportErrorCode.invalidValue => 'Value outside the supported limits',
      EqImportErrorCode.tooManyFilters =>
        'EQ profiles can have at most ${EqConfiguration.maximumFilters} '
            'filters.',
      EqImportErrorCode.noFilters => 'At least one filter is required.',
      EqImportErrorCode.invalidPreamp =>
        'Preamp is outside the supported range.',
      EqImportErrorCode.fixedBandNeedsPeaking =>
        'Fixed-band profiles require peaking filters.',
      EqImportErrorCode.graphicTooFewPoints =>
        'A GraphicEQ curve needs at least two points.',
    };
    return detail == null ? '$base$where.' : '$base$where: $detail';
  }
}

enum EqImportWarningCode {
  /// Several `Preamp:` lines were added together, as Equalizer APO does.
  preampSummed,

  /// No preamp was given; automatic headroom prevents clipping.
  preampMissing,

  /// An instruction Navis does not apply (Device, Include, Delay, ...).
  instructionIgnored,

  /// A filter of a type Navis cannot reproduce (band-pass, all-pass, ...).
  filterDropped,

  /// Only the first channel selection was imported.
  channelsLimited,

  /// Left and right differ; the left channel was imported.
  splitChannels,

  /// A graphic curve was approximated; [EqImportWarning.detail] holds the
  /// fit error.
  graphicFitted,
}

@immutable
class EqImportWarning {
  const EqImportWarning(this.code, {this.line, this.detail});

  final EqImportWarningCode code;
  final int? line;
  final String? detail;
}

@immutable
class EqImportResult {
  const EqImportResult({
    required this.preset,
    required this.format,
    this.warnings = const <EqImportWarning>[],
  });

  final EqPreset preset;
  final EqImportFormat format;
  final List<EqImportWarning> warnings;
}
