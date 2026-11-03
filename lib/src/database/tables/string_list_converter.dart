import 'dart:convert';

import 'package:drift/drift.dart';

/// Persists a [List<String>] as a JSON text column (`["Rock","Jazz"]`), in the
/// style of `ArtistRefListConverter`. An empty list is `'[]'`.
class StringListConverter extends TypeConverter<List<String>, String> {
  const new();

  @override
  List<String> fromSql(String fromDb) =>
      (jsonDecode(fromDb) as List<dynamic>).cast<String>();

  @override
  String toSql(List<String> value) => jsonEncode(value);
}
