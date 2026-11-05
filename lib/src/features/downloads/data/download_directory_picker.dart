import 'dart:io';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// Asks the user for a downloads folder, or null when they cancel.
///
/// file_picker's macOS folder panel has no New Folder button
/// (`canCreateDirectories` is never set), so macOS uses the Runner's own
/// panel and falls back to file_picker only if that channel is missing.
Future<String?> pickDownloadDirectory({
  required String title,
  bool useNativeMacPanel = false,
}) async {
  if (useNativeMacPanel || Platform.isMacOS) {
    try {
      return await const MethodChannel('com.navis.app/directory_picker')
          .invokeMethod<String>('pick', {'title': title});
    } on MissingPluginException {
      // Older Runner without the channel: the picker still works.
    }
  }
  return await FilePicker.getDirectoryPath(
    dialogTitle: title,
    androidOptions: Platform.isAndroid
        ? FilePickerAndroidOptions(
            safOptions: AndroidSAFOptions(
              grant: AndroidSAFGrant.lifetime,
              accessMode: AndroidSAFAccessMode.readWrite,
              persistGrant: true,
            ),
          )
        : const AndroidOptions(),
  );
}
