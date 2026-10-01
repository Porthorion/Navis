/// Process-local generation used by recommendation caches that contain song IDs.
///
/// Persisted aliases are authoritative. This epoch only ensures that in-memory
/// derived caches are rebuilt after a sync retires provisional IDs.
class SongIdentityCacheEpoch {
  new _();

  static int _value = 0;

  static int get value => _value;

  static void invalidate() {
    _value++;
  }
}
