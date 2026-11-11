import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/player/data/macos_dock_menu_bridge.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/notifications/notification_localizations.dart';

/// Keeps the macOS Dock menu in step with playback; a no-op elsewhere.
/// Watched by the app shell, which stays mounted while the window is hidden.
final macosDockMenuProvider = Provider<void>((ref) {
  if (kIsWeb || !Platform.isMacOS) return;
  final handler = ref.watch(audioHandlerProvider);
  if (handler == null) return;
  final bridge = MacosDockMenuBridge(
    handler: handler,
    localizations: resolveNotificationLocalizations(
      ref.watch(appLocaleProvider),
    ),
  );
  ref.onDispose(() => unawaited(bridge.dispose()));
});
