import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Decodes one cover and averages it into a colour field, or null when it has
/// no usable art. Injectable so tests can count and gate decodes.
typedef CoverColourDecoder = Future<CoverColourField?> Function(String coverId);

/// Decodes running at once. Sampling is background work; two keep the raster
/// and IO threads free for scrolling while still draining a screenful quickly.
const int kCoverColourMaxConcurrentDecodes = 2;

/// Fields kept on disk; the newest survive. Each costs about 50 bytes.
const int kCoverColourPersistedCapacity = 5000;

/// Wait after the last new sample before the store is rewritten.
const Duration kCoverColourPersistDelay = Duration(seconds: 2);

/// Disk home of sampled colour fields.
abstract interface class CoverColourStore {
  /// Every stored field, oldest first; empty when nothing usable is stored.
  Future<Map<String, CoverColourField>> load();

  /// Replaces the stored fields with [entries] (oldest first).
  Future<void> save(Map<String, CoverColourField> entries);
}

/// A store that keeps nothing. Used until an account is known.
class NullCoverColourStore implements CoverColourStore {
  const new();

  @override
  Future<Map<String, CoverColourField>> load() async =>
      <String, CoverColourField>{};

  @override
  Future<void> save(Map<String, CoverColourField> entries) async {}
}

/// Compact binary file in the application support directory.
///
/// Layout: magic `NCF1`, a length-prefixed scope string, an entry count, then
/// per entry a length-prefixed UTF-8 id and nine ARGB words. The scope names
/// the server and user the colours were sampled from, so cover ids that
/// collide across accounts never mix; a file of another scope reads as empty
/// and is overwritten by the next save. Reads and writes are asynchronous
/// and failures read as an empty store, so a bad file only costs a resample.
class FileCoverColourStore implements CoverColourStore {
  new({required this.scope, Future<Directory> Function()? readRootDirectory})
    : _readRootDirectory = readRootDirectory ?? getApplicationSupportDirectory;

  static const fileName = 'cover_colour_fields.bin';
  static const _magic = <int>[0x4e, 0x43, 0x46, 0x31];

  final String scope;
  final Future<Directory> Function() _readRootDirectory;

  Future<File> _file() async =>
      File(p.join((await _readRootDirectory()).path, fileName));

  @override
  Future<Map<String, CoverColourField>> load() async {
    try {
      final file = await _file();
      // Keep filesystem checks off the UI isolate.
      // ignore: avoid_slow_async_io
      if (!await file.exists()) return <String, CoverColourField>{};
      return decodeCoverColourStore(await file.readAsBytes(), scope: scope);
    } on Object catch (error) {
      AppLogger.debug('CoverColourStore: load failed: $error');
      return <String, CoverColourField>{};
    }
  }

  @override
  Future<void> save(Map<String, CoverColourField> entries) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(
        encodeCoverColourStore(entries, scope: scope),
        flush: true,
      );
      await temp.rename(file.path);
    } on Object catch (error) {
      AppLogger.debug('CoverColourStore: save failed: $error');
    }
  }
}

/// Encodes [entries] in the [FileCoverColourStore] layout.
@visibleForTesting
Uint8List encodeCoverColourStore(
  Map<String, CoverColourField> entries, {
  required String scope,
}) {
  final builder = BytesBuilder()..add(FileCoverColourStore._magic);
  final header = ByteData(4);
  void addString(String value) {
    final bytes = utf8.encode(value);
    header.setUint16(0, bytes.length);
    builder
      ..add(header.buffer.asUint8List(0, 2))
      ..add(bytes);
  }

  addString(scope);
  header.setUint32(0, entries.length);
  builder.add(header.buffer.asUint8List(0, 4));
  final cells = ByteData(kCoverColourGrid * kCoverColourGrid * 4);
  for (final MapEntry(:key, :value) in entries.entries) {
    if (utf8.encode(key).length > 0xffff) continue;
    addString(key);
    for (var i = 0; i < value.colors.length; i++) {
      cells.setUint32(i * 4, value.colors[i].toARGB32());
    }
    builder.add(cells.buffer.asUint8List());
  }
  return builder.takeBytes();
}

/// Decodes a [FileCoverColourStore] file; empty for another [scope] or any
/// malformed input.
@visibleForTesting
Map<String, CoverColourField> decodeCoverColourStore(
  Uint8List bytes, {
  required String scope,
}) {
  final result = <String, CoverColourField>{};
  try {
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    for (final byte in FileCoverColourStore._magic) {
      if (data.getUint8(offset++) != byte) return result;
    }
    String readString() {
      final length = data.getUint16(offset);
      offset += 2;
      final value = utf8.decode(bytes.sublist(offset, offset + length));
      offset += length;
      return value;
    }

    if (readString() != scope) return result;
    final count = data.getUint32(offset);
    offset += 4;
    for (var i = 0; i < count; i++) {
      final id = readString();
      final colors = <Color>[
        for (var c = 0; c < kCoverColourGrid * kCoverColourGrid; c++)
          Color(data.getUint32(offset + c * 4)),
      ];
      offset += kCoverColourGrid * kCoverColourGrid * 4;
      result[id] = CoverColourField(colors);
    }
  } on Object {
    // A truncated file keeps the entries read before the damage.
  }
  return result;
}

/// A caller's claim on a cover's colours. [cancel] withdraws it: when every
/// claim on a cover is cancelled before its decode starts, the decode never
/// runs.
class CoverColourRequest {
  new _(this._sampler, this.coverId);

  final CoverColourSampler _sampler;
  final String coverId;
  final Completer<CoverColourField?> _completer =
      Completer<CoverColourField?>();
  CoverArtLoadInterest? _interest;

  /// The field, or null when the cover has no usable local art yet, the
  /// decode failed or the request was cancelled.
  Future<CoverColourField?> get future => _completer.future;

  void cancel() => _sampler._cancel(this);
}

class _Job {
  new(this.coverId);

  final String coverId;
  final List<CoverColourRequest> requests = <CoverColourRequest>[];
}

/// The coordinator key of a cover's colour sample.
@visibleForTesting
String coverColourLoadKey(String coverId) =>
    'tint:${coverArtImageCacheKey(coverId, kCoverArtStandardSize)}';

/// The app-wide cover colour sampler.
///
/// A request resolves from the memory cache, then the persistent store (read
/// once, asynchronously, into memory), and only then decodes the cover's
/// already-local artwork. The decode is scheduled through a
/// [CoverArtLoadCoordinator]: every request tracks interest in its cover, so
/// a decode still queued when its last card is gone is cancelled by the
/// coordinator's stale-interest logic, and the coordinator's active-slot
/// limit bounds concurrent decodes. Requests for one cover share one decode.
class CoverColourSampler {
  new({
    required this.decode,
    required this.cache,
    required this.coordinator,
    this.store = const NullCoverColourStore(),
    this.persistedCapacity = kCoverColourPersistedCapacity,
    this.persistDelay = kCoverColourPersistDelay,
  }) {
    _ready = _loadStore();
  }

  final CoverColourDecoder decode;
  final CoverColourFieldCache cache;
  final CoverArtLoadCoordinator coordinator;
  final CoverColourStore store;
  final int persistedCapacity;
  final Duration persistDelay;

  final Map<String, CoverColourField> _persisted = <String, CoverColourField>{};
  final Map<String, _Job> _jobs = <String, _Job>{};
  late final Future<void> _ready;
  bool _disposed = false;
  Timer? _persistTimer;
  Future<void> _saving = Future<void>.value();

  /// Completes once the persistent store has been read into memory.
  Future<void> get ready => _ready;

  Future<void> _loadStore() async {
    try {
      final loaded = await store.load();
      if (_disposed) return;
      // Anything sampled while loading is newer than the stored entries.
      final fresh = Map<String, CoverColourField>.of(_persisted);
      _persisted
        ..clear()
        ..addAll(loaded)
        ..addAll(fresh);
      _trim();
      // Warm the memory cache with the newest fields so cards that build
      // after this paint their tint on the first frame.
      final newest = _persisted.entries
          .toList()
          .reversed
          .take(cache.capacity)
          .toList()
          .reversed;
      for (final MapEntry(:key, :value) in newest) {
        if (cache.peek(key) == null) cache.put(key, value);
      }
    } on Object catch (error) {
      AppLogger.debug('CoverColourSampler: store load failed: $error');
    }
  }

  /// Asks for [coverId]'s colours. Memory hits complete without scheduling.
  CoverColourRequest request(String coverId) {
    final request = CoverColourRequest._(this, coverId);
    final cached = cache.get(coverId);
    if (cached != null || _disposed) {
      request._completer.complete(cached);
      return request;
    }
    final existing = _jobs[coverId];
    final job = existing ?? _Job(coverId);
    job.requests.add(request);
    request._interest = coordinator.trackInterest(
      coverColourLoadKey(coverId),
      CoverArtLoadPriority.visible,
    );
    if (existing == null) {
      _jobs[coverId] = job;
      unawaited(_run(job));
    }
    return request;
  }

  void _cancel(CoverColourRequest request) {
    request._interest?.dispose();
    request._interest = null;
    if (!request._completer.isCompleted) request._completer.complete(null);
    final job = _jobs[request.coverId];
    if (job == null) return;
    job.requests.remove(request);
    // A new request for this cover must not join a job nobody wants.
    if (job.requests.isEmpty) _jobs.remove(request.coverId);
  }

  Future<void> _run(_Job job) async {
    CoverColourField? field;
    try {
      await _ready;
      field = _persisted[job.coverId];
      if (field != null) {
        cache.put(job.coverId, field);
        return;
      }
      if (job.requests.isEmpty || _disposed) return;
      final CoverArtLoadLease lease;
      try {
        lease = await coordinator.acquire(coverColourLoadKey(job.coverId));
      } on CoverArtLoadCanceledException {
        return;
      }
      try {
        if (job.requests.isEmpty || _disposed) return;
        field = await decode(job.coverId);
      } finally {
        lease.release();
      }
      if (field != null && !_disposed) {
        cache.put(job.coverId, field);
        _persisted
          ..remove(job.coverId)
          ..[job.coverId] = field;
        _schedulePersist();
      }
    } on Object catch (error) {
      field = null;
      AppLogger.debug('CoverColourSampler: sampling failed: $error');
    } finally {
      if (identical(_jobs[job.coverId], job)) _jobs.remove(job.coverId);
      for (final request in job.requests) {
        request._interest?.dispose();
        request._interest = null;
        if (!request._completer.isCompleted) request._completer.complete(field);
      }
      job.requests.clear();
    }
  }

  void _trim() {
    while (_persisted.length > persistedCapacity) {
      _persisted.remove(_persisted.keys.first);
    }
  }

  void _schedulePersist() {
    if (_persistTimer != null) return;
    _persistTimer = Timer(persistDelay, _writeNow);
  }

  void _writeNow() {
    _persistTimer = null;
    _trim();
    final snapshot = Map<String, CoverColourField>.of(_persisted);
    _saving = _saving.then((_) => store.save(snapshot));
  }

  /// Writes any unsaved fields now; resolves once the store has them.
  Future<void> flush() async {
    if (_persistTimer != null) {
      _persistTimer!.cancel();
      _writeNow();
    }
    await _saving;
  }

  void dispose() {
    _disposed = true;
    _persistTimer?.cancel();
    _persistTimer = null;
    for (final job in _jobs.values) {
      for (final request in job.requests) {
        request._interest?.dispose();
        request._interest = null;
        if (!request._completer.isCompleted) request._completer.complete(null);
      }
      job.requests.clear();
    }
    _jobs.clear();
  }
}

/// Side of the decode used for sampling; small enough to read instantly.
const int _kSampleSize = 24;

/// Reads a cover that is already on this device and averages it into a
/// colour field. It never touches the network: the permanent artwork store
/// and the rolling cache are looked up locally, and a cover that is in
/// neither yields null (the card retries once its artwork has loaded).
Future<CoverColourField?> decodeLocalCoverColour(
  Ref ref,
  String coverId,
) async {
  final permanent = ref.read(permanentArtworkStoreProvider);
  var file =
      permanent.loadedFileFor(coverId) ?? await permanent.fileFor(coverId);
  if (file == null) {
    final cached = await ref
        .read(coverArtCacheManagerProvider)
        .getFileFromCache(
          coverArtImageCacheKey(coverId, kCoverArtStandardSize),
        );
    file = cached?.file;
  }
  if (file == null) return null;
  final info = await resolveImageInfo(
    ResizeImage(FileImage(file), width: _kSampleSize, height: _kSampleSize),
  );
  if (info == null) return null;
  try {
    final bytes = await info.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (bytes == null) return null;
    final colors = averageColourGrid(
      bytes,
      info.image.width,
      info.image.height,
    );
    if (colors.any((color) => color.a == 0)) return null;
    return CoverColourField(colors);
  } finally {
    info.dispose();
  }
}

/// Decoder used by the app (see [decodeLocalCoverColour]). Replaced in tests.
final coverColourDecoderProvider = Provider<CoverColourDecoder>((ref) {
  return (coverId) => decodeLocalCoverColour(ref, coverId);
});

/// Coordinator for colour decodes. Separate from the artwork coordinator on
/// purpose: that one's slots also gate real artwork downloads, and a flood of
/// tint decodes must never delay them. Two slots, no critical reserve.
final coverColourLoadCoordinatorProvider = Provider<CoverArtLoadCoordinator>(
  (ref) => CoverArtLoadCoordinator(maxActiveDownloads: 2, criticalReserve: 0),
);

/// Identifies the server and user covers are sampled from, so ids of another
/// account never reuse these colours. Null without a client. Holds no
/// credentials.
final coverColourScopeProvider = Provider<String?>((ref) {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) return null;
  try {
    final url = api.getCoverArtUrl(id: '_', size: 1);
    final origin = '${url.scheme}://${url.authority}${url.path}';
    final digest = sha256.convert(
      utf8.encode(jsonEncode(<String>[origin, api.authConfig.username])),
    );
    return digest.toString().substring(0, 16);
  } on Object {
    return null;
  }
});

/// The persistent colour store of the current account.
final coverColourStoreProvider = Provider<CoverColourStore>((ref) {
  final scope = ref.watch(coverColourScopeProvider);
  return scope == null
      ? const NullCoverColourStore()
      : FileCoverColourStore(scope: scope);
});

/// The single app-wide sampler (see [CoverColourSampler]). Rebuilt, with an
/// empty memory cache, when the account changes.
final coverColourSamplerProvider = Provider<CoverColourSampler>((ref) {
  sharedCoverColourFieldCache.clear();
  final sampler = CoverColourSampler(
    decode: (coverId) => ref.read(coverColourDecoderProvider)(coverId),
    cache: sharedCoverColourFieldCache,
    coordinator: ref.watch(coverColourLoadCoordinatorProvider),
    store: ref.watch(coverColourStoreProvider),
  );
  ref.onDispose(sampler.dispose);
  return sampler;
});

final Map<String, int> _missingArtRetries = <String, int>{};

/// Colour field for a cover, from memory, the persistent store or a bounded
/// decode of locally stored artwork (see [CoverColourSampler]). Disposing the
/// provider cancels a request that has not started decoding. A cover that is
/// not on the device yet is retried a few times, one, two and four seconds
/// apart, while something still watches it.
final coverColourFieldProvider = FutureProvider.autoDispose
    .family<CoverColourField?, String>((ref, coverId) async {
      final request = ref.watch(coverColourSamplerProvider).request(coverId);
      ref.onDispose(request.cancel);
      final field = await request.future;
      if (field != null) {
        _missingArtRetries.remove(coverId);
      } else if (ref.mounted) {
        final attempt = _missingArtRetries[coverId] ?? 0;
        if (attempt < 3) {
          _missingArtRetries[coverId] = attempt + 1;
          final timer = Timer(Duration(seconds: 1 << attempt), () {
            if (ref.mounted) ref.invalidateSelf();
          });
          ref.onDispose(timer.cancel);
        } else {
          _missingArtRetries.remove(coverId);
        }
      }
      return field;
    });
