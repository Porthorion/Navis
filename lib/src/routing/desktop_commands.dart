import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Named command actions supported by the desktop shell.
enum DesktopCommandAction {
  focusSearch,
  toggleQueue,
  toggleNowPlaying,
  playPause,
  nextTrack,
  previousTrack,
}

class DesktopCommandIntent extends Intent {
  const DesktopCommandIntent(this.action);

  final DesktopCommandAction action;
}

typedef DesktopCommandExecutor =
    FutureOr<void> Function(
      DesktopCommandAction action,
    );

bool desktopCommandBlockedByTextInput(BuildContext context) {
  final focusContext = FocusManager.instance.primaryFocus?.context;
  if (focusContext == null) {
    return false;
  }
  if (focusContext.widget is EditableText ||
      focusContext.widget is TextField ||
      focusContext.widget is TextFormField) {
    return true;
  }
  return focusContext.findAncestorWidgetOfExactType<EditableText>() != null ||
      focusContext.findAncestorWidgetOfExactType<TextField>() != null ||
      focusContext.findAncestorWidgetOfExactType<TextFormField>() != null;
}

Map<ShortcutActivator, Intent> buildDesktopShortcutMap(
  TargetPlatform platform,
) {
  final isApple = platform == TargetPlatform.macOS;

  return <ShortcutActivator, Intent>{
    SingleActivator(
      LogicalKeyboardKey.keyK,
      meta: isApple,
      control: !isApple,
    ): const DesktopCommandIntent(
      DesktopCommandAction.focusSearch,
    ),
    SingleActivator(
      LogicalKeyboardKey.keyJ,
      meta: isApple,
      control: !isApple,
    ): const DesktopCommandIntent(
      DesktopCommandAction.toggleQueue,
    ),
    const SingleActivator(LogicalKeyboardKey.escape):
        const DesktopCommandIntent(DesktopCommandAction.toggleNowPlaying),
    const SingleActivator(LogicalKeyboardKey.space): const DesktopCommandIntent(
      DesktopCommandAction.playPause,
    ),
    const SingleActivator(LogicalKeyboardKey.arrowRight):
        const DesktopCommandIntent(DesktopCommandAction.nextTrack),
    const SingleActivator(LogicalKeyboardKey.arrowLeft):
        const DesktopCommandIntent(DesktopCommandAction.previousTrack),
    SingleActivator(
      LogicalKeyboardKey.period,
      alt: true,
      includeRepeats: false,
    ): const DesktopCommandIntent(
      DesktopCommandAction.nextTrack,
    ),
    SingleActivator(LogicalKeyboardKey.comma, alt: true, includeRepeats: false):
        const DesktopCommandIntent(DesktopCommandAction.previousTrack),
  };
}

class DesktopCommandActionHandler extends Action<DesktopCommandIntent> {
  DesktopCommandActionHandler({
    required this.context,
    required this.executor,
  });

  final BuildContext context;
  final DesktopCommandExecutor executor;

  @override
  Object? invoke(DesktopCommandIntent intent) {
    final action = intent.action;
    final textSensitive =
        action == DesktopCommandAction.playPause ||
        action == DesktopCommandAction.nextTrack ||
        action == DesktopCommandAction.previousTrack;
    if (textSensitive && desktopCommandBlockedByTextInput(context)) {
      return null;
    }
    executor(action);
    return null;
  }
}
