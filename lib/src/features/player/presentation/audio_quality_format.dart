// Audio-quality text shared by the mobile Now Playing info grid and the
// desktop media-info dialog.

int? readSampleRateFromExtras(Map<String, dynamic>? extras) {
  if (extras == null || extras.isEmpty) {
    return null;
  }

  const keys = <String>[
    'resolvedSampleRate',
    'sampleRate',
    'samplingRate',
    'sample_rate',
    'sampling_rate',
  ];

  for (final key in keys) {
    final raw = extras[key];
    if (raw == null) {
      continue;
    }
    if (raw is int) {
      return raw > 0 ? raw : null;
    }
    if (raw is double) {
      final rounded = raw.round();
      return rounded > 0 ? rounded : null;
    }
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) {
        return parsed;
      }
      final parsedDouble = double.tryParse(raw.trim());
      if (parsedDouble != null) {
        final rounded = parsedDouble.round();
        if (rounded > 0) {
          return rounded;
        }
      }
    }
  }

  return null;
}

String? audioFormatLabel(String? format) {
  final normalized = format?.trim();
  if (normalized != null && normalized.isNotEmpty) {
    if (normalized.toLowerCase() == 'transcoded') {
      return null;
    }
    return normalized.toUpperCase();
  }
  return null;
}

String? inferAudioFormat(String? contentType) {
  if (contentType == null || !contentType.contains('/')) {
    return null;
  }
  final subtype = contentType.split('/').last.trim();
  if (subtype.isEmpty) {
    return null;
  }
  return subtype.toUpperCase();
}

String formatBitRate(int bitRate) {
  if (bitRate >= 1024) {
    final mbps = bitRate / 1024;
    final text = mbps % 1 == 0
        ? mbps.toStringAsFixed(0)
        : mbps.toStringAsFixed(1);
    return '$text Mb/s';
  }
  return '$bitRate Kb/s';
}

String formatSampleRate(int sampleRateHz) {
  final sampleRateKhz = sampleRateHz / 1000;
  final text = sampleRateKhz % 1 == 0
      ? sampleRateKhz.toStringAsFixed(0)
      : sampleRateKhz.toStringAsFixed(1);
  return '$text kHz';
}
