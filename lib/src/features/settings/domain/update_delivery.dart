/// How an available update should be delivered to the user.
enum UpdateDelivery {
  /// Download and apply a desktop artifact in-app.
  desktopSelfUpdate,

  /// Download an APK from the update host and trigger the system installer.
  selfUpdate,

  /// Redirect the user to the platform store listing (e.g. Google Play).
  storeRedirect,
}
