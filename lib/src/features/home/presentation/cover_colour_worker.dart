// The core mirrors the isolate message layout, so flags travel positionally.
// ignore_for_file: avoid_positional_boolean_parameters

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// Number of colours in a cover's colour field (a 3×3 grid).
const int kCoverColourCells = 9;

/// Fields kept on disk; the newest survive. Each costs about 54 bytes.
const int kCoverColourPersistedCapacity = 5000;

/// Wait after the last new sample before the file is rewritten.
const Duration kCoverColourPersistDelay = Duration(seconds: 2);

/// Averages an RGBA buffer into a 3×3 row-major grid of ARGB ints.
///
/// Transparent pixels are ignored so letterboxed covers do not wash out. A
/// cell with no opaque pixel is 0 (transparent), which callers treat as "no
/// usable art".
List<int> averageArgbGrid(Uint8List rgba, int width, int height) {
  const grid = 3;
  final sums = List<int>.filled(grid * grid * 4, 0);
  for (var y = 0; y < height; y++) {
    final row = (y * grid ~/ height).clamp(0, grid - 1);
    for (var x = 0; x < width; x++) {
      final column = (x * grid ~/ width).clamp(0, grid - 1);
      final offset = (y * width + x) * 4;
      if (rgba[offset + 3] == 0) continue;
      final cell = (row * grid + column) * 4;
      sums[cell] += rgba[offset];
      sums[cell + 1] += rgba[offset + 1];
      sums[cell + 2] += rgba[offset + 2];
      sums[cell + 3] += 1;
    }
  }
  return <int>[
    for (var i = 0; i < grid * grid; i++)
      if (sums[i * 4 + 3] == 0)
        0
      else
        0xFF000000 |
            ((sums[i * 4] ~/ sums[i * 4 + 3]) << 16) |
            ((sums[i * 4 + 1] ~/ sums[i * 4 + 3]) << 8) |
            (sums[i * 4 + 2] ~/ sums[i * 4 + 3]),
  ];
}

const List<int> _magic = <int>[0x4e, 0x43, 0x46, 0x32];

/// Encodes [entries] (id to nine ARGB ints, oldest first) in the layout of
/// `cover_colour_fields.bin`: magic `NCF2`, a length-prefixed scope string,
/// an entry count, then per entry a length-prefixed UTF-8 id and nine ARGB
/// words and a 32-bit artwork revision. NCF1 files load with revision zero.
/// The scope names the server and user the colours came from.
Uint8List encodeColourStoreEntries(
  Map<String, List<int>> entries, {
  required String scope,
}) {
  final builder = BytesBuilder()..add(_magic);
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
  final cells = ByteData((kCoverColourCells + 1) * 4);
  for (final MapEntry(:key, :value) in entries.entries) {
    if (utf8.encode(key).length > 0xffff) continue;
    addString(key);
    for (var i = 0; i < kCoverColourCells; i++) {
      cells.setUint32(i * 4, value[i]);
    }
    cells.setUint32(kCoverColourCells * 4, value.length > 9 ? value[9] : 0);
    builder.add(cells.buffer.asUint8List());
  }
  return builder.takeBytes();
}

/// Decodes a store file; empty for another [scope] or malformed input. A
/// truncated file keeps the entries read before the damage.
Map<String, List<int>> decodeColourStoreEntries(
  Uint8List bytes, {
  required String scope,
}) {
  final result = <String, List<int>>{};
  try {
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    for (final byte in _magic.take(3)) {
      if (data.getUint8(offset++) != byte) return result;
    }
    final version = data.getUint8(offset++);
    if (version != 0x31 && version != 0x32) return result;
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
      final colors = <int>[
        for (var c = 0; c < kCoverColourCells; c++)
          data.getUint32(offset + c * 4),
      ];
      offset += kCoverColourCells * 4;
      colors.add(version == 0x32 ? data.getUint32(offset) : 0);
      if (version == 0x32) offset += 4;
      result[id] = colors;
    }
  } on Object {
    // Keep what was read.
  }
  return result;
}

/// Everything the cover colour feature computes away from the UI isolate:
/// pixel averaging, caption-tint maths and the persistent file (read, merge,
/// trim, encode, write). Results are plain ints and lists so they cross an
/// isolate port cheaply.
abstract interface class CoverColourWorker {
  /// [averageArgbGrid] of an RGBA buffer.
  Future<List<int>> averageGrid(Uint8List rgba, int width, int height);

  /// [captionTintFor] for [sampled] in [style]: fill, text and subtext as
  /// `[a, r, g, b]` doubles each (the subtitle's alpha is not a whole byte).
  Future<List<double>> captionTint(Color sampled, NavisColorStyleData style);

  /// Opens the colour file at [path] for [scope]; returns the newest [warm]
  /// entries (oldest first) as `[id, argb × 9, revision]` lists.
  Future<List<List<Object>>> openStore(String path, String scope, int warm);

  /// The stored colours and sampled revision of [id], or null.
  Future<List<int>?> lookup(String id);

  /// Records [colors] (nine ARGB cells, then revision) for [id]; written to
  /// disk after a quiet period.
  void add(String id, List<int> colors);

  /// Writes pending additions now.
  Future<void> flush();

  Future<void> dispose();
}

/// The worker's logic, shared by the isolate and in-process workers.
class CoverColourWorkerCore {
  new({
    this.capacity = kCoverColourPersistedCapacity,
    this.persistDelay = kCoverColourPersistDelay,
  });

  final int capacity;
  final Duration persistDelay;
  final Map<String, List<int>> _entries = <String, List<int>>{};
  String? _path;
  String _scope = '';
  Timer? _timer;
  bool _dirty = false;
  Future<void> _writing = Future<void>.value();

  List<int> averageGrid(Uint8List rgba, int width, int height) =>
      averageArgbGrid(rgba, width, height);

  List<double> captionTint(
    int sampled,
    int styleIndex,
    bool dark, [
    int vividness = 0,
    int depth = 0,
  ]) {
    final tint = captionTintFor(
      Color(sampled),
      NavisColorStyleData(
        style: NavisColorStyle.values[styleIndex],
        dark: dark,
        adjustment: ColorAdjustment(vividness: vividness, depth: depth),
      ),
    );
    return <double>[
      for (final c in [tint.fill, tint.text, tint.subtext]) ...[
        c.a,
        c.r,
        c.g,
        c.b,
      ],
    ];
  }

  Future<List<List<Object>>> openStore(
    String path,
    String scope,
    int warm,
  ) async {
    if (_path != null && scope != _scope) {
      _entries.clear();
      _dirty = false;
      _timer?.cancel();
      _timer = null;
    }
    _path = path;
    _scope = scope;
    try {
      final file = File(path);
      // Runs in the worker isolate, never on the UI isolate.
      // ignore: avoid_slow_async_io
      if (await file.exists()) {
        final loaded = decodeColourStoreEntries(
          await file.readAsBytes(),
          scope: scope,
        );
        if (_scope != scope || _path != path) return const [];
        // Anything added under this scope while loading is newer than the file.
        final fresh = Map<String, List<int>>.of(_entries);
        _entries
          ..clear()
          ..addAll(loaded)
          ..addAll(fresh);
        _trim();
      }
    } on Object {
      // An unreadable file reads as empty.
    }
    final all = _entries.entries.toList();
    final newest = all.length > warm ? all.sublist(all.length - warm) : all;
    return <List<Object>>[
      for (final MapEntry(:key, :value) in newest) <Object>[key, ...value],
    ];
  }

  List<int>? lookup(String id) => _entries[id];

  void add(String id, List<int> colors) {
    _entries
      ..remove(id)
      ..[id] = colors;
    _dirty = true;
    _timer ??= Timer(persistDelay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final path = _path;
    if (path != null && _dirty) {
      _dirty = false;
      _trim();
      final bytes = encodeColourStoreEntries(_entries, scope: _scope);
      _writing = _writing.then((_) async {
        try {
          final file = File(path);
          await file.parent.create(recursive: true);
          final temp = File('$path.tmp');
          await temp.writeAsBytes(bytes, flush: true);
          await temp.rename(path);
        } on Object {
          // A failed write only costs a resample.
        }
      });
    }
    await _writing;
  }

  void _trim() {
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  Future<void> dispose() => flush();
}

List<Object> _styleArgs(NavisColorStyleData style) => <Object>[
  style.style.index,
  style.dark,
  style.adjustment.vividness,
  style.adjustment.depth,
];

/// Runs the work in this isolate. For tests and as a fallback; the app uses
/// [IsolateCoverColourWorker].
@visibleForTesting
class InlineCoverColourWorker implements CoverColourWorker {
  new({CoverColourWorkerCore? core}) : core = core ?? CoverColourWorkerCore();

  final CoverColourWorkerCore core;

  @override
  Future<List<int>> averageGrid(Uint8List rgba, int width, int height) async =>
      core.averageGrid(rgba, width, height);

  @override
  Future<List<double>> captionTint(
    Color sampled,
    NavisColorStyleData style,
  ) async {
    final a = _styleArgs(style);
    return core.captionTint(
      sampled.toARGB32(),
      a[0] as int,
      a[1] as bool,
      a[2] as int,
      a[3] as int,
    );
  }

  @override
  Future<List<List<Object>>> openStore(String path, String scope, int warm) =>
      core.openStore(path, scope, warm);

  @override
  Future<List<int>?> lookup(String id) async => core.lookup(id);

  @override
  void add(String id, List<int> colors) => core.add(id, colors);

  @override
  Future<void> flush() => core.flush();

  @override
  Future<void> dispose() => core.dispose();
}

/// A long-lived worker isolate, started on first use.
class IsolateCoverColourWorker implements CoverColourWorker {
  new();

  Future<SendPort>? _port;
  ReceivePort? _replies;
  Isolate? _isolate;
  int _nextId = 0;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  bool _disposed = false;

  Future<SendPort> _start() async {
    final replies = ReceivePort();
    _replies = replies;
    final ready = Completer<SendPort>();
    replies.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      final [int id, Object? result, Object? error] = message as List;
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (error != null) {
        completer.completeError(StateError('$error'));
      } else {
        completer.complete(result);
      }
    });
    _isolate = await Isolate.spawn<SendPort>(
      _entry,
      replies.sendPort,
      debugName: 'cover-colour-worker',
    );
    return await ready.future;
  }

  static void _entry(SendPort replyTo) {
    final commands = ReceivePort();
    replyTo.send(commands.sendPort);
    final core = CoverColourWorkerCore();
    commands.listen((message) async {
      final [int id, String op, List<dynamic> args] = message as List;
      try {
        Object? result;
        switch (op) {
          case 'average':
            result = core.averageGrid(
              args[0] as Uint8List,
              args[1] as int,
              args[2] as int,
            );
          case 'tint':
            result = core.captionTint(
              args[0] as int,
              args[1] as int,
              args[2] as bool,
              args[3] as int,
              args[4] as int,
            );
          case 'open':
            result = await core.openStore(
              args[0] as String,
              args[1] as String,
              args[2] as int,
            );
          case 'lookup':
            result = core.lookup(args[0] as String);
          case 'add':
            core.add(args[0] as String, (args[1] as List<dynamic>).cast<int>());
          case 'flush':
            await core.flush();
        }
        replyTo.send(<Object?>[id, result, null]);
      } on Object catch (error) {
        replyTo.send(<Object?>[id, null, error.toString()]);
      }
    });
  }

  Future<T> _call<T>(String op, List<Object?> args) async {
    if (_disposed) throw StateError('worker disposed');
    final port = await (_port ??= _start());
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send(<Object?>[id, op, args]);
    return (await completer.future) as T;
  }

  @override
  Future<List<int>> averageGrid(Uint8List rgba, int width, int height) async =>
      (await _call<List<dynamic>>('average', [
        rgba,
        width,
        height,
      ])).cast<int>();

  @override
  Future<List<double>> captionTint(
    Color sampled,
    NavisColorStyleData style,
  ) async => (await _call<List<dynamic>>('tint', [
    sampled.toARGB32(),
    ..._styleArgs(style),
  ])).cast<double>();

  @override
  Future<List<List<Object>>> openStore(
    String path,
    String scope,
    int warm,
  ) async => (await _call<List<dynamic>>('open', [
    path,
    scope,
    warm,
  ])).map((e) => (e as List<dynamic>).cast<Object>()).toList();

  @override
  Future<List<int>?> lookup(String id) async =>
      (await _call<List<dynamic>?>('lookup', [id]))?.cast<int>();

  @override
  void add(String id, List<int> colors) {
    if (_disposed) return;
    unawaited(_call<Object?>('add', [id, colors]).catchError((_) => null));
  }

  @override
  Future<void> flush() async {
    if (_port == null) return;
    await _call<Object?>('flush', const []);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await flush();
    } on Object {
      // Nothing more to save.
    }
    _disposed = true;
    _isolate?.kill();
    _replies?.close();
    for (final completer in _pending.values) {
      completer.completeError(StateError('worker disposed'));
    }
    _pending.clear();
  }
}

/// The app's worker isolate for cover colour work.
final coverColourWorkerProvider = Provider<CoverColourWorker>((ref) {
  final worker = IsolateCoverColourWorker();
  ref.onDispose(() => unawaited(worker.dispose()));
  return worker;
});
