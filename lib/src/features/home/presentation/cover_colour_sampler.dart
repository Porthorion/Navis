import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/home/presentation/cover_colour_worker.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Decodes one cover and averages it into a colour field, or null when it has
/// no usable art. Injectable so tests can count and gate decodes.
typedef CoverColourDecoder = Future<CoverColourField?> Function(
  String coverId, {
  int revision,
});

/// Disk home of sampled colour fields. Every operation is asynchronous and
/// the heavy parts run off the UI isolate (see [CoverColourWorker]).
abstract interface class CoverColourStore {
  /// The newest [count] stored fields, oldest first.
  Future<List<MapEntry<String, CoverColourField>>> warm(int count);

  /// The stored field of [id], or null.
  Future<CoverColourField?> lookup(String id);

  /// Records a freshly sampled field; persisted after a quiet period.
  void add(String id, CoverColourField field);

  /// Persists pending additions now.
  Future<void> flush();
}

/// A store that keeps nothing. Used until an account is known.
class NullCoverColourStore implements CoverColourStore {
  const new();

  @override
  Future<List<MapEntry<String, CoverColourField>>> warm(int count) async =>
      const <MapEntry<String, CoverColourField>>[];

  @override
  Future<CoverColourField?> lookup(String id) async => null;

  @override
  void add(String id, CoverColourField field) {}

  @override
  Future<void> flush() async {}
}

CoverColourField _fieldOf(List<int> argb) => CoverColourField(<Color>[
  for (final c in argb.take(9)) Color(c),
], revision: argb.length > 9 ? argb[9] : 0);

List<int> _argbOf(CoverColourField field) => <int>[
  for (final c in field.colors) c.toARGB32(),
  field.revision,
];

/// Compact binary file `cover_colour_fields.bin` in the application support
/// directory (layout in [encodeColourStoreEntries]), read, merged, trimmed
/// and written by the [CoverColourWorker]; the UI isolate only sends and
/// receives small lists. A file of another [scope] reads as empty and is
/// overwritten by the next save; failures read as an empty store.
class FileCoverColourStore implements CoverColourStore {
  new({
    required this.scope,
    required this.worker,
    Future<Directory> Function()? readRootDirectory,
  }) : _readRootDirectory = readRootDirectory ?? getApplicationSupportDirectory;

  static const fileName = 'cover_colour_fields.bin';

  final String scope;
  final CoverColourWorker worker;
  final Future<Directory> Function() _readRootDirectory;
  Future<List<List<Object>>>? _opened;

  Future<List<List<Object>>> _open(int warm) => _opened ??= () async {
    try {
      final dir = await _readRootDirectory();
      return await worker.openStore(p.join(dir.path, fileName), scope, warm);
    } on Object catch (error) {
      AppLogger.debug('CoverColourStore: open failed: $error');
      return <List<Object>>[];
    }
  }();

  @override
  Future<List<MapEntry<String, CoverColourField>>> warm(int count) async => [
    for (final entry in await _open(count))
      MapEntry(
        entry.first as String,
        _fieldOf(entry.skip(1).cast<int>().toList()),
      ),
  ];

  @override
  Future<CoverColourField?> lookup(String id) async {
    await _open(0);
    try {
      final colors = await worker.lookup(id);
      return colors == null ? null : _fieldOf(colors);
    } on Object {
      return null;
    }
  }

  @override
  void add(String id, CoverColourField field) => worker.add(id, _argbOf(field));

  @override
  Future<void> flush() => worker.flush();
}

/// A caller's claim on a cover's colours. [cancel] withdraws it: when every
/// claim on a cover is cancelled before its decode starts, the decode never
/// runs.
class CoverColourRequest {
  new _(this._sampler, this.coverId, this.revision);

  final CoverColourSampler _sampler;
  final String coverId;
  final int revision;
  final Completer<CoverColourField?> _completer =
      Completer<CoverColourField?>();
  CoverArtLoadInterest? _interest;

  /// The field, or null when the cover has no usable local art yet, the
  /// decode failed or the request was cancelled.
  Future<CoverColourField?> get future => _completer.future;

  void cancel() => _sampler._cancel(this);
}

class _Job {
  new(this.coverId, this.revision);

  final String coverId;
  final int revision;
  (String, int) get key => (coverId, revision);
  final List<CoverColourRequest> requests = <CoverColourRequest>[];
}

/// The coordinator key of a cover's colour sample.
@visibleForTesting
String coverColourLoadKey(String coverId, {int revision = 0}) =>
    'tint:${coverArtImageCacheKey(coverId, kCoverArtStandardSize, revision: revision)}';

/// The app-wide cover colour sampler.
///
/// A request resolves from the memory cache, then the persistent store (an
/// asynchronous lookup in the worker isolate), and only then decodes the cover's
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
  }) {
    _ready = _loadStore();
  }

  final CoverColourDecoder decode;
  final CoverColourFieldCache cache;
  final CoverArtLoadCoordinator coordinator;
  final CoverColourStore store;

  final Map<(String, int, CoverArtLoadPriority), int> _missingArtRetries =
      <(String, int, CoverArtLoadPriority), int>{};
  final Map<(String, int), _Job> _jobs = <(String, int), _Job>{};
  late final Future<void> _ready;
  bool _disposed = false;

  /// Completes once the persistent store has been read into memory.
  Future<void> get ready => _ready;

  Future<void> _loadStore() async {
    try {
      // Warm the memory cache with the newest fields so cards that build
      // after this paint their tint on the first frame.
      for (final MapEntry(:key, :value) in await store.warm(cache.capacity)) {
        if (!_disposed && cache.peek(key) == null) cache.put(key, value);
      }
    } on Object catch (error) {
      AppLogger.debug('CoverColourSampler: store load failed: $error');
    }
  }

  /// Asks for [coverId]'s [revision]. Current memory hits complete without
  /// scheduling; stale fields stay cached until the replacement is ready.
  CoverColourRequest request(
    String coverId, {
    int revision = 0,
    CoverArtLoadPriority priority = CoverArtLoadPriority.visible,
  }) {
    final request = CoverColourRequest._(this, coverId, revision);
    final cached = cache.get(coverId);
    if ((cached != null && cached.revision >= revision) || _disposed) {
      request._completer.complete(cached);
      return request;
    }
    final key = (coverId, revision);
    final existing = _jobs[key];
    final job = existing ?? _Job(coverId, revision);
    job.requests.add(request);
    request._interest = coordinator.trackInterest(
      coverColourLoadKey(coverId, revision: revision),
      priority,
    );
    if (existing == null) {
      _jobs[key] = job;
      unawaited(_run(job));
    }
    return request;
  }

  void _cancel(CoverColourRequest request) {
    request._interest?.dispose();
    request._interest = null;
    if (!request._completer.isCompleted) request._completer.complete(null);
    final job = _jobs[(request.coverId, request.revision)];
    if (job == null) return;
    job.requests.remove(request);
    // A new request for this cover must not join a job nobody wants.
    if (job.requests.isEmpty) _jobs.remove((request.coverId, request.revision));
  }

  Future<void> _run(_Job job) async {
    CoverColourField? field;
    try {
      await _ready;
      if (job.requests.isEmpty || _disposed) return;
      field = await store.lookup(job.coverId);
      if (field != null && field.revision >= job.revision) {
        cache.put(job.coverId, field);
        return;
      }
      if (job.requests.isEmpty || _disposed) return;
      final CoverArtLoadLease lease;
      try {
        lease = await coordinator.acquire(
          coverColourLoadKey(job.coverId, revision: job.revision),
        );
      } on CoverArtLoadCanceledException {
        return;
      }
      try {
        if (job.requests.isEmpty || _disposed) return;
        field = await decode(job.coverId, revision: job.revision);
        if (field != null) {
          field = CoverColourField(field.colors, revision: job.revision);
        }
      } finally {
        lease.release();
      }
      if (field != null && !_disposed) {
        // A newer job may finish while this one decodes, and its memory
        // entry may already have been evicted. Check the same store too.
        final stored = await store.lookup(job.coverId);
        if (!_disposed &&
            (stored?.revision ?? -1) <= job.revision &&
            (cache.peek(job.coverId)?.revision ?? -1) <= job.revision) {
          cache.put(job.coverId, field);
          store.add(job.coverId, field);
        }
      }
    } on Object catch (error) {
      field = null;
      AppLogger.debug('CoverColourSampler: sampling failed: $error');
    } finally {
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      for (final request in job.requests) {
        request._interest?.dispose();
        request._interest = null;
        if (!request._completer.isCompleted) request._completer.complete(field);
      }
      job.requests.clear();
    }
  }

  /// Persists unsaved fields now; resolves once the store has them.
  Future<void> flush() => store.flush();

  void dispose() {
    _disposed = true;
    _missingArtRetries.clear();
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
///
/// The file is decoded natively at 24 px without entering the shared image
/// cache (tint decodes must not evict real artwork); only the 2 KB pixel
/// buffer reaches Dart, and the averaging runs in the [CoverColourWorker].
/// Refreshed revisions require their own cache key: an old permanent copy
/// must not be recorded as if it were fresh.
Future<CoverColourField?> decodeLocalCoverColour(
  Ref ref,
  String coverId, {
  int revision = 0,
}) async {
  File? file;
  if (revision == 0) {
    final permanent = ref.read(permanentArtworkStoreProvider);
    file = permanent.loadedFileFor(coverId) ?? await permanent.fileFor(coverId);
  }
  if (file == null) {
    final manager = ref.read(coverArtCacheManagerProvider);
    // Album heroes/cards use 600; showcase mosaics use 480/420 and the
    // mini-cover strip uses 96. Only inspect files, never fetch artwork.
    for (final size in [kCoverArtStandardSize, 480, 420, 96]) {
      final cached = await manager.getFileFromCache(
        coverArtImageCacheKey(coverId, size, revision: revision),
      );
      if (cached != null) {
        file = cached.file;
        break;
      }
    }
  }
  if (file == null) return null;
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec(
      targetWidth: _kSampleSize,
      targetHeight: _kSampleSize,
    );
    image = (await codec.getNextFrame()).image;
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) return null;
    final argb = await ref
        .read(coverColourWorkerProvider)
        .averageGrid(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          image.width,
          image.height,
        );
    if (argb.any((c) => c >> 24 == 0)) return null;
    return _fieldOf(argb);
  } on Object catch (error) {
    AppLogger.debug('CoverColourSampler: decode failed: $error');
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Decoder used by the app (see [decodeLocalCoverColour]). Replaced in tests.
final coverColourDecoderProvider = Provider<CoverColourDecoder>((ref) {
  return (coverId, {revision = 0}) =>
      decodeLocalCoverColour(ref, coverId, revision: revision);
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
      : FileCoverColourStore(
          scope: scope,
          worker: ref.watch(coverColourWorkerProvider),
        );
});

/// The single app-wide sampler (see [CoverColourSampler]). Rebuilt, with an
/// empty memory cache, when the account changes.
final coverColourSamplerProvider = Provider<CoverColourSampler>((ref) {
  sharedCoverColourFieldCache.clear();
  final sampler = CoverColourSampler(
    decode: (coverId, {revision = 0}) =>
        ref.read(coverColourDecoderProvider)(coverId, revision: revision),
    cache: sharedCoverColourFieldCache,
    coordinator: ref.watch(coverColourLoadCoordinatorProvider),
    store: ref.watch(coverColourStoreProvider),
  );
  ref.onDispose(() {
    unawaited(sampler.flush());
    sampler.dispose();
  });
  return sampler;
});

/// Colour field for a cover, from memory, the persistent store or a bounded
/// decode of locally stored artwork (see [CoverColourSampler]). Disposing the
/// provider cancels a request that has not started decoding. A cover that is
/// not on the device yet is retried a few times, one, two and four seconds
/// apart, while something still watches it.
final coverColourFieldProvider = FutureProvider.autoDispose
    .family<CoverColourField?, (String, int)>(
      (ref, key) => _loadColourField(ref, key, CoverArtLoadPriority.visible),
    );

/// Best-effort colour fields for decorative meshes and backdrops.
///
/// Captions retain visible priority on the same sampler and coordinator.
final backgroundCoverColourFieldProvider = FutureProvider.autoDispose
    .family<CoverColourField?, (String, int)>(
      (ref, key) => _loadColourField(ref, key, CoverArtLoadPriority.background),
    );

Future<CoverColourField?> _loadColourField(
  Ref ref,
  (String, int) cover,
  CoverArtLoadPriority priority,
) async {
  final (coverId, revision) = cover;
  final key = (coverId, revision, priority);
  final sampler = ref.watch(coverColourSamplerProvider);
  final request = sampler.request(
    coverId,
    revision: revision,
    priority: priority,
  );
  Timer? retryTimer;
  var retryPending = false;
  ref.onDispose(() {
    if (!retryPending) {
      sampler._missingArtRetries.remove(key);
    }
    retryTimer?.cancel();
  });
  ref.onDispose(request.cancel);
  final field = await request.future;
  if (field != null) {
    sampler._missingArtRetries.remove(key);
  } else if (ref.mounted) {
    final attempt = sampler._missingArtRetries[key] ?? 0;
    if (attempt < 3) {
      sampler._missingArtRetries[key] = attempt + 1;
      retryTimer = Timer(Duration(seconds: 1 << attempt), () {
        if (ref.mounted) {
          // Keep the attempt count across this deliberate recomputation.
          retryPending = true;
          ref.invalidateSelf();
        }
      });
    } else {
      sampler._missingArtRetries.remove(key);
    }
  }
  return field;
}
