import 'package:flutter/foundation.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/utils/constants.dart';

/// Trusted Android installer packages that indicate a store-delivered install.
///
/// Mirrors [tool/diagnose_android_auto.sh] trusted-installer semantics.
const Set<String> trustedStoreInstallers = {
  'com.android.vending', // Google Play
  'com.skt.skaf.A000Z00040', // Samsung Galaxy Store
  'com.onestore.android.updater', // ONE store
  'com.onestore.android.pkgmgr',
};

/// Resolves how an update should be delivered for the current platform and
/// install source.
UpdateDelivery resolveUpdateDelivery({
  required bool isAndroid,
  required bool selfUpdateBuildEnabled,
  String? installerPackage,
  bool isIOS = false,
}) {
  if (isIOS) return UpdateDelivery.releasePage;
  if (!isAndroid) {
    return UpdateDelivery.desktopSelfUpdate;
  }

  if (!selfUpdateBuildEnabled) {
    return UpdateDelivery.storeRedirect;
  }

  final installer = installerPackage?.trim();
  if (installer != null &&
      installer.isNotEmpty &&
      trustedStoreInstallers.contains(installer)) {
    return UpdateDelivery.storeRedirect;
  }

  return UpdateDelivery.selfUpdate;
}

/// Whether the compile-time self-update capability is enabled for this build.
bool get selfUpdateBuildEnabled => AppConstants.selfUpdateEnabled;

/// Whether update checks and update settings exist on this platform. iOS has
/// them only in the sideload build; App Store and TestFlight builds hide them.
bool updateUiAvailableFor({
  bool? isWeb,
  TargetPlatform? platform,
  bool? iosSideload,
}) =>
    !(isWeb ?? kIsWeb) &&
    ((platform ?? defaultTargetPlatform) != TargetPlatform.iOS ||
        (iosSideload ?? AppConstants.iosSideload));

/// [updateUiAvailableFor] for the running build.
bool get updateUiAvailable => updateUiAvailableFor();
