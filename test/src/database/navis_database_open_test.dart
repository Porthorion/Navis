import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'background engines defer while the app has not migrated the schema',
    () async {
      final directory = await Directory.systemTemp.createTemp('navis-open-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File(p.join(directory.path, 'navis.sqlite'));

      expect(
        NavisDatabase.schemaUpgradePending(file),
        isTrue,
        reason: 'missing',
      );
      expect(file.existsSync(), isFalse, reason: 'the gate never creates it');

      final database = NavisDatabase.atPath(file.path);
      await database.customSelect('SELECT 1').get();
      await database.close();
      expect(NavisDatabase.schemaUpgradePending(file), isFalse);

      final raw = sqlite3.open(file.path);
      raw.execute('PRAGMA user_version = 102');
      raw.close();
      expect(NavisDatabase.schemaUpgradePending(file), isTrue, reason: 'older');

      final check = sqlite3.open(file.path);
      addTearDown(check.close);
      expect(check.userVersion, 102, reason: 'the gate never migrates');

      check.execute(
        'PRAGMA user_version = ${NavisDatabase.currentSchemaVersion + 1}',
      );
      expect(NavisDatabase.schemaUpgradePending(file), isTrue, reason: 'newer');

      file.writeAsBytesSync(List.filled(64, 7));
      expect(
        NavisDatabase.schemaUpgradePending(file),
        isTrue,
        reason: 'unreadable',
      );
    },
  );
}
