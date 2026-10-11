import 'package:flutter/services.dart';

/// Available bytes on the filesystem containing an existing directory.
/// SAF providers do not expose capacity; their staging directory is checked.
Future<int?> downloadStorageFreeBytes(String directory) async {
  try {
    return await const MethodChannel('com.navis.app/storage_capacity')
        .invokeMethod<int>('freeBytes', {'path': directory});
  } on MissingPluginException {
    return null;
  } on PlatformException {
    // Some filesystems cannot report capacity. Write errors still hold work.
    return null;
  }
}
