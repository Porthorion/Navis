import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  final manifest = XmlDocument.parse(
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
  );
  test('application disables backup and declares extraction rules', () {
    final app = manifest.findAllElements('application').single;
    expect(app.getAttribute('android:allowBackup'), 'false');
    expect(
      app.getAttribute('android:dataExtractionRules'),
      '@xml/data_extraction_rules',
    );
    final rules = XmlDocument.parse(
      File('android/app/src/main/res/xml/data_extraction_rules.xml')
          .readAsStringSync(),
    );
    for (final kind in ['cloud-backup', 'device-transfer']) {
      final exclusions = rules
          .findAllElements(kind)
          .single
          .findElements('exclude');
      expect(
        exclusions.map((entry) => entry.getAttribute('domain')),
        unorderedEquals(['root', 'file', 'database', 'sharedpref', 'external']),
      );
      expect(
        exclusions.every((entry) => entry.getAttribute('path') == '.'),
        isTrue,
      );
    }
  });
  test('mailto handlers are visible to url_launcher', () {
    final intents = manifest
        .findAllElements('queries')
        .single
        .findElements('intent');
    expect(
      intents.any(
        (intent) =>
            intent
                .findElements('action')
                .any(
                  (action) =>
                      action.getAttribute('android:name') ==
                      'android.intent.action.SENDTO',
                ) &&
            intent
                .findElements('data')
                .any((data) => data.getAttribute('android:scheme') == 'mailto'),
      ),
      isTrue,
    );
  });
}
