part of 'navis_audio_handler.dart';

/// Sizes of the released queue window.
///
/// Long queues keep only the part around the current song in the native
/// player ("materialised"); later songs wait in a Dart-only deferred tail and
/// are released in pages as playback approaches them. See "Released queue
/// window" in docs/architecture.md.
@immutable
class NavisQueueWindow {
  const NavisQueueWindow({
    this.deferThreshold = 256,
    this.ahead = 32,
    this.lowWater = 12,
    this.page = 32,
    this.nearJump = 64,
  });

  /// Replacement queues longer than this defer the songs after [ahead].
  final int deferThreshold;

  /// Songs materialised after the start song when a queue is replaced.
  final int ahead;

  /// A release starts once fewer materialised songs than this remain after
  /// the current one.
  final int lowWater;

  /// Songs released per background refill.
  final int page;

  /// A jump this far or less into the tail releases through the target;
  /// farther jumps rebuild the player around it.
  final int nearJump;
}

/// A queued song that has not been handed to the native player yet.
@immutable
class _DeferredQueueEntry {
  const _DeferredQueueEntry(this.id, [this.song]);

  final String id;

  /// The caller's row for remote songs. A remote row can be identity-matched
  /// to a local song, so it must not be re-read by id when released. Local
  /// songs keep only the id and are read fresh at release.
  final SongsTableData? song;
}

/// A list that counts its changes, so derived views such as the logical queue
/// ids can be cached per revision instead of rebuilt on every playback event.
class _RevisionedList<E> extends ListBase<E> {
  final List<E> _items = <E>[];

  /// Increases on every change; never decreases.
  int revision = 0;

  @override
  int get length => _items.length;

  @override
  set length(int value) {
    _items.length = value;
    revision++;
  }

  @override
  E operator [](int index) => _items[index];

  @override
  void operator []=(int index, E value) {
    _items[index] = value;
    revision++;
  }

  @override
  void add(E element) {
    _items.add(element);
    revision++;
  }

  @override
  void addAll(Iterable<E> iterable) {
    _items.addAll(iterable);
    revision++;
  }

  @override
  void insert(int index, E element) {
    _items.insert(index, element);
    revision++;
  }

  @override
  void insertAll(int index, Iterable<E> iterable) {
    _items.insertAll(index, iterable);
    revision++;
  }

  @override
  E removeAt(int index) {
    revision++;
    return _items.removeAt(index);
  }

  @override
  E removeLast() {
    revision++;
    return _items.removeLast();
  }

  @override
  void removeRange(int start, int end) {
    _items.removeRange(start, end);
    revision++;
  }

  @override
  bool remove(Object? element) {
    final removed = _items.remove(element);
    if (removed) revision++;
    return removed;
  }

  @override
  void removeWhere(bool Function(E element) test) {
    _items.removeWhere(test);
    revision++;
  }

  @override
  void clear() {
    _items.clear();
    revision++;
  }
}
