/// An insertion-ordered cache that evicts its least recently used entry.
/// Values are owned by the caller; the callback runs only for capacity eviction.
class BoundedLruMap<K, V extends Object> {
  new({required this._capacity, this._onEvict})
    : assert(_capacity >= 0, 'Cache capacity must not be negative.');

  final int _capacity;
  final void Function(V value)? _onEvict;
  final Map<K, V> _entries = <K, V>{};

  /// Returns the cached value, optionally leaving its recency unchanged.
  V? get(K key, {bool refreshRecency = true}) {
    final value = _entries[key];
    if (value != null && refreshRecency) {
      _entries
        ..remove(key)
        ..[key] = value;
    }
    return value;
  }

  /// Inserts or replaces a value, marking it most recently used.
  void put(K key, V value) {
    _entries
      ..remove(key)
      ..[key] = value;
    while (_entries.length > _capacity) {
      final evicted = _entries.remove(_entries.keys.first)!;
      _onEvict?.call(evicted);
    }
  }

  int get length => _entries.length;

  Iterable<V> get values => _entries.values;

  /// Forgets entries without invoking the capacity-eviction callback.
  void clear() => _entries.clear();
}
