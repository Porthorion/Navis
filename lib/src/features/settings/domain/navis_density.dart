/// App-wide density for Home and lists.
enum NavisDensity {
  comfortable('comfortable'),
  compact('compact');

  new(this.storageKey);

  /// Value persisted in `app_settings.home_density`.
  final String storageKey;

  /// Resolves a stored value, falling back to [comfortable] for unknown values.
  static NavisDensity parse(String? value) {
    for (final option in values) {
      if (option.storageKey == value) return option;
    }
    return comfortable;
  }
}
