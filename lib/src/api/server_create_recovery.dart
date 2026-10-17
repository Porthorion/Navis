import 'dart:async';
import 'dart:io';

import 'package:navis/src/api/subsonic_error.dart';

typedef ServerCreateIdentity = ({String id, String name});

/// Resolves bodyless or uncertain creates using new ids, retaining the original
/// snapshot until the caller has committed its local replacement.
class ServerCreateRecovery<T> {
  final _pending = <String, _PendingCreate<T>>{};
  final _active = <String, Future<({String id, T snapshot})>>{};

  Future<({String id, T snapshot})> run(
    String key, {
    required T snapshot,
    required String name,
    required Future<List<ServerCreateIdentity>> Function() list,
    required Future<String?> Function() create,
  }) => _active.putIfAbsent(
    key,
    () => _run(key, snapshot, name, list, create).whenComplete(() {
      unawaited(_active.remove(key));
    }),
  );

  Future<({String id, T snapshot})> _run(
    String key,
    T snapshot,
    String name,
    Future<List<ServerCreateIdentity>> Function() list,
    Future<String?> Function() create,
  ) async {
    var pending = _pending[key];
    if (pending == null) {
      final before = await list();
      pending = _PendingCreate(
        snapshot,
        name,
        before.map((row) => row.id).toSet(),
      );
      _pending[key] = pending;
      try {
        pending.id = await create();
      } on Object catch (error) {
        if (error is! SubsonicConnectionException &&
            error is! TimeoutException &&
            error is! SocketException) {
          _pending.remove(key);
          rethrow;
        }
        // The server may have committed. Resolve before allowing another create.
      }
    }
    if (pending.id == null) {
      final matches = (await list())
          .where(
            (row) =>
                !pending!.before.contains(row.id) && row.name == pending.name,
          )
          .toList();
      if (matches.length != 1 || matches.single.id.isEmpty) {
        throw StateError(
          'Could not identify the created server item. The device copy was kept.',
        );
      }
      pending.id = matches.single.id;
    }
    return (id: pending.id!, snapshot: pending.snapshot);
  }

  void complete(String key) => _pending.remove(key);
}

class _PendingCreate<T> {
  new(this.snapshot, this.name, this.before);

  final T snapshot;
  final String name;
  final Set<String> before;
  String? id;
}
