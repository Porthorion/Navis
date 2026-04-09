import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:navis/src/api/models/artist_ref.dart';

/// Drift [TypeConverter] that persists a [List<ArtistRef>] as a JSON text
/// column (e.g. `[{"id":"1","name":"Alice"},{"id":"2","name":"Bob"}]`).
///
/// An empty list serialises to `'[]'`, which is also the SQL column default
/// so existing rows upgraded via migration automatically get `[]` without
/// needing an UPDATE pass.
class ArtistRefListConverter extends TypeConverter<List<ArtistRef>, String> {
  const ArtistRefListConverter();

  @override
  List<ArtistRef> fromSql(String fromDb) {
    final list = jsonDecode(fromDb) as List<dynamic>;
    return list
        .map((e) => ArtistRef.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  String toSql(List<ArtistRef> value) {
    return jsonEncode(value.map((e) => e.toJson()).toList());
  }
}
