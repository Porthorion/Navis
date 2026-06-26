import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_delivery_resolver.dart';

void main() {
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
        UpdateDelivery.forgejoSelfUpdate,
      );
    });

    test('uses forgejo self-update when installer is unknown', () {
      expect(
        resolveUpdateDelivery(
          isAndroid: true,
          selfUpdateBuildEnabled: true,
          installerPackage: null,
        ),
        UpdateDelivery.forgejoSelfUpdate,
      );
    });
  });
}
