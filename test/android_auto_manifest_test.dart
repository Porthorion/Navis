import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';
  const automotiveDescPath =
      'android/app/src/main/res/xml/automotive_app_desc.xml';

  late String manifest;
  late String automotiveDesc;

  setUpAll(() {
    manifest = File(manifestPath).readAsStringSync();
    automotiveDesc = File(automotiveDescPath).readAsStringSync();
  });

  test('declares Android Auto media app metadata at application level', () {
    expect(
      manifest,
      contains('android:name="com.google.android.gms.car.application"'),
    );
    expect(manifest, contains('android:resource="@xml/automotive_app_desc"'));
    expect(
      manifest,
      contains('android:name="androidx.car.app.TintableAttributionIcon"'),
    );
    expect(
      manifest,
      contains(
        'android:name="com.google.android.gms.car.application.theme"',
      ),
    );
    expect(automotiveDesc, contains('<uses name="media"'));
  });

  test('exports media browser service with car-visible metadata', () {
    expect(
      manifest,
      contains('android:name="com.ryanheise.audioservice.AudioService"'),
    );
    expect(manifest, contains('android:label="@string/app_name"'));
    expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
    expect(manifest, contains('android:exported="true"'));
    expect(manifest, contains('android:foregroundServiceType="mediaPlayback"'));
    expect(
      manifest,
      contains('android:name="android.media.browse.MediaBrowserService"'),
    );
    expect(
      manifest,
      isNot(contains('android.permission.BIND_MEDIA_BROWSER_SERVICE')),
    );
  });
}
