import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late AppSettingsTableData settings;

  setUp(() async {
    database = createTestDatabase();
    await database.appSettingsDao.updateCustomDownloadFolderEnabled(
      enabled: true,
    );
    settings = (await database.appSettingsDao.getSettings())!;
  });

  tearDown(() => database.close());

  AppSettingsTableData? isolate(
    String? folder, {
    bool clone = true,
    String root = '/work/diag-run',
  }) => isolateCloneDownloadFolder(
    settings.copyWith(customDownloadFolderPath: Value(folder)),
    cloneDiagnostics: clone,
    diagnosticsRoot: root,
  );

  test('a clone never uses a download folder outside its root', () {
    final isolated = isolate('/home/user/Downloads/Navis_Downloads');
    expect(isolated?.customDownloadFolderEnabled, isFalse);
    expect(isolated?.customDownloadFolderPath, isNull);
    // A sibling whose name merely starts with the root is outside it.
    expect(
      isolate('/work/diag-run-other/downloads')?.customDownloadFolderEnabled,
      isFalse,
    );
    expect(
      isolate('/work/diag-run/../elsewhere')?.customDownloadFolderEnabled,
      isFalse,
    );
  });

  test('folders inside the root, tree URIs and normal runs are kept', () {
    for (final kept in <AppSettingsTableData?>[
      isolate('/work/diag-run/user-folder'),
      isolate('content://com.android.externalstorage.documents/tree/x'),
      isolate('/home/user/Downloads/Navis_Downloads', clone: false),
      isolate('/home/user/Downloads/Navis_Downloads', root: ''),
    ]) {
      expect(kept?.customDownloadFolderEnabled, isTrue);
      expect(kept?.customDownloadFolderPath, isNotNull);
    }
  });

  test('the same rule decides which folders a clone may choose', () {
    bool rejects(String path, {bool clone = true, String root = '/work/run'}) =>
        cloneDownloadFolderOutsideRoot(
          path,
          cloneDiagnostics: clone,
          diagnosticsRoot: root,
        );

    expect(rejects('/home/user/Downloads/Navis_Downloads'), isTrue);
    expect(rejects('/work/run-other/downloads'), isTrue);
    expect(rejects('/work/run/../elsewhere'), isTrue);
    expect(rejects('/work/run/fixture-folder'), isFalse);
    expect(
      rejects('content://com.android.externalstorage.documents/tree/x'),
      isFalse,
    );
    expect(rejects('/home/user/Downloads', clone: false), isFalse);
    expect(rejects('/home/user/Downloads', root: ''), isFalse);
  });
}
