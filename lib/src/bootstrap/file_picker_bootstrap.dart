import 'package:file_picker/file_picker.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Lets the unsandboxed macOS app open the picker.
///
/// The Darwin plugin refuses every dialog when the bundle declares no
/// user-selected-file entitlement, which is the case for Navis. The opt-out is
/// a no-op on the other platforms, so a failure here must never block startup.
Future<void> configureFilePicker() async {
  try {
    await FilePicker.skipEntitlementsChecks();
  } on Object catch (error) {
    AppLogger.warning(
      'File picker entitlement opt-out failed: ${error.runtimeType}',
    );
  }
}
