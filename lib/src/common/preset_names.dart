/// Failures shared by named tuning, appearance and playback presets.
enum PresetFailure {
  emptyName,
  duplicateName,
  reservedName,
  notFound,
  persistence,
}

/// Validates a trimmed name without changing the caller's collection.
PresetFailure? validatePresetName(
  String name, {
  required Iterable<({String id, String name})> presets,
  Set<String> reservedNames = const {},
  String? excludingId,
}) {
  final normalized = name.trim().toLowerCase();
  if (normalized.isEmpty) {
    return PresetFailure.emptyName;
  }
  if (reservedNames.contains(normalized)) {
    return PresetFailure.reservedName;
  }
  if (presets.any(
    (p) => p.id != excludingId && p.name.trim().toLowerCase() == normalized,
  )) {
    return PresetFailure.duplicateName;
  }
  return null;
}

/// A named preset or the reason it could not be saved.
class PresetResult<T> {
  const new success(T this.value) : failure = null;
  const new failure(PresetFailure this.failure) : value = null;
  final T? value;
  final PresetFailure? failure;
}
