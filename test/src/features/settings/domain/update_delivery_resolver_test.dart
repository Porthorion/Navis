import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_delivery_resolver.dart';

void main() {
  group('updateUiAvailableFor', () {
    test('shows on iOS only in the sideload build', () {
      expect(
        updateUiAvailableFor(platform: TargetPlatform.iOS, iosSideload: false),
        isFalse,
      );
      expect(
        updateUiAvailableFor(platform: TargetPlatform.iOS, iosSideload: true),
        isTrue,
      );
    });

    test('is unchanged elsewhere and never shows on the web', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        expect(
          updateUiAvailableFor(platform: platform, iosSideload: false),
          isTrue,
        );
      }
      expect(
        updateUiAvailableFor(
          isWeb: true,
          platform: TargetPlatform.iOS,
          iosSideload: true,
        ),
        isFalse,
      );
    });
  });

  group('resolveUpdateDelivery', () {
    test('uses desktop self-update off Android', () {
      expect(
        resolveUpdateDelivery(
          isAndroid: false,
          selfUpdateBuildEnabled: true,
          installerPackage: null,
        ),
        UpdateDelivery.desktopSelfUpdate,
      );
    });

    test('links to the release page on the iOS sideload build', () {
      expect(
        resolveUpdateDelivery(
          isAndroid: false,
          isIOS: true,
          selfUpdateBuildEnabled: true,
        ),
        UpdateDelivery.releasePage,
      );
    });

    test('uses store redirect when self-update build is disabled', () {
      expect(
        resolveUpdateDelivery(
          isAndroid: true,
          selfUpdateBuildEnabled: false,
          installerPackage: null,
        ),
        UpdateDelivery.storeRedirect,
      );
    });

    test('uses store redirect for Google Play installer', () {
      expect(
        resolveUpdateDelivery(
          isAndroid: true,
          selfUpdateBuildEnabled: true,
          installerPackage: 'com.android.vending',
        ),
        UpdateDelivery.storeRedirect,
      );
    });

    test('uses store redirect for Samsung Galaxy Store installer', () {
      expect(
        resolveUpdateDelivery(
          isAndroid: true,
          selfUpdateBuildEnabled: true,
          installerPackage: 'com.skt.skaf.A000Z00040',
        ),
        UpdateDelivery.storeRedirect,
      );
    });

    test('uses forgejo self-update for sideloaded installs', () {
      expect(
        resolveUpdateDelivery(
          isAndroid: true,
          selfUpdateBuildEnabled: true,
          installerPackage: 'com.android.shell',
        ),
        UpdateDelivery.selfUpdate,
      );
    });

    test('uses forgejo self-update when installer is unknown', () {
      expect(
        resolveUpdateDelivery(
          isAndroid: true,
          selfUpdateBuildEnabled: true,
          installerPackage: null,
        ),
        UpdateDelivery.selfUpdate,
      );
    });
  });
}
