/// Keeps the latest position until the source is ready for native seeking.
///
/// Native seeks are serialized. A completion for a superseded position cannot
/// clear the current request, including when a new source is opened meanwhile.
class DeferredSeek {
  DeferredSeek({required this.apply, required this.isReady});

  final Future<void> Function(Duration) apply;
  final bool Function() isReady;
  Duration? _position;
  int _revision = 0;
  Future<void>? _flight;

  /// Whether an unapplied position remains.
  bool get isPending => _position != null;

  /// Replaces pending work with the initial position of a new source.
  void beginLoad(Duration? position) {
    _revision++;
    _position = position == Duration.zero ? null : position;
  }

  /// Supersedes the pending position without interrupting a native call.
  void request(Duration position) {
    _revision++;
    _position = position;
  }

  /// Applies retained positions while the current source is ready.
  Future<void> flush() {
    final flight = _flight;
    if (flight != null) return flight;
    final result = _drain();
    _flight = result;
    return result.whenComplete(() => _flight = null);
  }

  Future<void> _drain() async {
    while (isReady() && _position != null) {
      final revision = _revision;
      final position = _position!;
      await apply(position);
      if (revision == _revision) _position = null;
    }
  }
}
