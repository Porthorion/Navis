import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// The native property boundary, replaceable without loading libmpv in tests.
abstract interface class IcyPropertySource {
  Future<String> read(String property);
  Future<void> observe(String property, Future<void> Function(String) listener);
  Future<void> unobserve(String property);
}

/// Tracks ICY metadata for the selected source.
class IcyMetadataObserver {
  IcyMetadataObserver({required this.source, required this.onChanged});

  final IcyPropertySource source;
  final void Function(IcyMetadataMessage?) onChanged;
  final _observed = <String>[];
  IcyMetadataMessage? _value;
  String? _uri;
  int _revision = 0;
  bool _disposed = false;
  Future<void>? _starting;

  IcyMetadataMessage? get value => _value;
  String? get sourceUri => _uri;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    for (final property in ['metadata']) {
      if (_disposed) return;
      await source.observe(property, (_) => refresh());
      _observed.add(property);
    }
    await refresh();
  }

  void setSource(String? uri) {
    ++_revision;
    _uri = uri;
    if (_value != null) {
      _value = null;
      onChanged(null);
    }
  }

  Future<void> refresh() async {
    final uri = _uri;
    if (_disposed || uri == null) return;
    final revision = ++_revision;
    // mpv can still report the old source between load() and file replacement.
    final initialPath = await source.read('path');
    if (_disposed || revision != _revision || initialPath != uri) return;
    final values = await Future.wait([
      source.read('metadata/by-key/icy-title'),
      source.read('metadata/by-key/icy-name'),
      source.read('metadata/by-key/icy-url'),
    ]);
    if (_disposed || revision != _revision) return;
    final icyTitle = values[0];
    final name = values[1];
    final url = values[2];
    final path = await source.read('path');
    if (_disposed || revision != _revision || path != uri) {
      return;
    }
    String? nonEmpty(String value) =>
        value.trim().isEmpty ? null : value.trim();
    final stationName = nonEmpty(name);
    final stationUrl = nonEmpty(url);
    // mpv's media-title falls back to the URL basename before ICY arrives.
    // Only stream metadata is authoritative for the current song.
    final title = nonEmpty(icyTitle);
    if (title == _value?.info?.title) return;
    _value = title == null
        ? null
        : IcyMetadataMessage(
            info: IcyInfoMessage(title: title, url: stationUrl),
            headers: IcyHeadersMessage(
              bitrate: null,
              genre: null,
              name: stationName,
              metadataInterval: null,
              url: stationUrl,
              isPublic: null,
            ),
          );
    onChanged(_value);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_revision;
    // Registration may still be waiting for the native player to initialize.
    await _starting;
    for (final property in _observed) {
      await source.unobserve(property);
    }
    _observed.clear();
  }
}
