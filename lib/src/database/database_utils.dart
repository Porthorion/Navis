/// Splits [items] into pages bounded by [size].
Iterable<List<T>> chunked<T>(List<T> items, int size) sync* {
  if (size <= 0) throw ArgumentError.value(size, 'size', 'Must be positive');
  for (var offset = 0; offset < items.length; offset += size) {
    yield items.sublist(offset, (offset + size).clamp(0, items.length));
  }
}
