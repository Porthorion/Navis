import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/routing/desktop_commands.dart';

class DesktopShortcutsSettingsScreen extends ConsumerStatefulWidget {
  const DesktopShortcutsSettingsScreen({super.key});

  @override
  ConsumerState<DesktopShortcutsSettingsScreen> createState() =>
      _DesktopShortcutsSettingsScreenState();
}

class _DesktopShortcutsSettingsScreenState
    extends ConsumerState<DesktopShortcutsSettingsScreen> {
  final FocusNode _captureFocusNode = FocusNode(
    debugLabel: 'desktopShortcutCapture',
  );
  DesktopCommandAction? _capturingAction;
  DesktopShortcutBinding? _capturedBinding;
  DesktopShortcutBinding? _originalBinding;

  /// Partially-held modifier combo shown while the user hasn't yet pressed the
  /// non-modifier key, e.g. "Ctrl+" or "Ctrl+Shift+". Null when idle.
  String? _liveInput;

  @override
  void dispose() {
    _captureFocusNode.dispose();
    super.dispose();
  }

  void _startCapture(
    DesktopCommandAction action,
    DesktopShortcutBinding? currentBinding,
  ) {
    setState(() {
      _capturingAction = action;
      _capturedBinding = currentBinding;
      _originalBinding = currentBinding;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_captureFocusNode.canRequestFocus) {
        return;
      }
      _captureFocusNode.requestFocus();
    });
  }

  void _cancelCapture() {
    setState(() {
      _capturingAction = null;
      _capturedBinding = _originalBinding;
      _originalBinding = null;
      _liveInput = null;
    });
  }

  void _commitCapture() {
    final action = _capturingAction;
    if (action == null) {
      return;
    }
    ref
        .read(desktopShortcutBindingsProvider.notifier)
        .setBinding(action, _capturedBinding);
    setState(() {
      _capturingAction = null;
      _originalBinding = null;
      _liveInput = null;
    });
  }

  bool _isModifierKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }

  DesktopShortcutBinding? _bindingFromEvent(
    KeyDownEvent event,
    TargetPlatform platform,
  ) {
    if (_isModifierKey(event.logicalKey)) {
      return null;
    }
    final keyboard = HardwareKeyboard.instance;
    final isApple = platform == TargetPlatform.macOS;
    final primaryModifier = isApple
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    final alt = keyboard.isAltPressed;
    final shift = keyboard.isShiftPressed;
    if (!primaryModifier && !alt && !shift) {
      return null;
    }
    return DesktopShortcutBinding(
      key: event.logicalKey,
      primaryModifier: primaryModifier,
      alt: alt,
      shift: shift,
    );
  }

  KeyEventResult _handleCaptureKey(
    FocusNode _,
    KeyEvent event,
    TargetPlatform platform,
  ) {
    if (_capturingAction == null) {
      return KeyEventResult.ignored;
    }

    // Handle key-up to refresh the live modifier display.
    if (event is KeyUpEvent) {
      if (_capturedBinding == null) _syncLiveInput(platform);
      return KeyEventResult.handled;
    }

    if (event is! KeyDownEvent) {
      return KeyEventResult.handled;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _cancelCapture();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _commitCapture();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      setState(() {
        _capturedBinding = null;
      });
      _syncLiveInput(platform);
      return KeyEventResult.handled;
    }

    // Modifier-only key: just update the live display.
    if (_isModifierKey(key)) {
      _syncLiveInput(platform);
      return KeyEventResult.handled;
    }

    final binding = _bindingFromEvent(event, platform);
    if (binding != null) {
      setState(() {
        _capturedBinding = binding;
        _liveInput = null;
      });
    } else {
      // No valid combo; keep showing live modifiers.
      _syncLiveInput(platform);
    }
    return KeyEventResult.handled;
  }

  /// Updates [_liveInput] based on which modifier keys are currently held.
  /// Called on modifier key-down/up when no complete binding is captured yet.
  void _syncLiveInput(TargetPlatform platform) {
    if (_capturedBinding != null) {
      if (_liveInput != null) setState(() => _liveInput = null);
      return;
    }
    final keyboard = HardwareKeyboard.instance;
    final isApple = platform == TargetPlatform.macOS;
    final parts = <String>[];
    if (isApple ? keyboard.isMetaPressed : keyboard.isControlPressed) {
      parts.add(isApple ? 'Cmd' : 'Ctrl');
    }
    // Super/Meta on Linux & Windows (Win key).
    if (!isApple && keyboard.isMetaPressed) parts.add('Super');
    if (keyboard.isAltPressed) parts.add(isApple ? 'Option' : 'Alt');
    if (keyboard.isShiftPressed) parts.add('Shift');
    final newInput = parts.isEmpty ? null : parts.join('+');
    if (_liveInput != newInput) setState(() => _liveInput = newInput);
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final shortcuts = ref.watch(desktopShortcutBindingsProvider);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Focus(
      focusNode: _captureFocusNode,
      onKeyEvent: (node, event) => _handleCaptureKey(node, event, platform),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Keyboard Shortcuts'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Reset to defaults',
              onPressed: () {
                ref
                    .read(desktopShortcutBindingsProvider.notifier)
                    .resetDefaults();
                _cancelCapture();
              },
              icon: const Icon(Icons.restore_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: <Widget>[
            // --- Configurable Shortcuts ---
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                'Customizable',
                style: textTheme.titleSmall?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final action in configurableDesktopShortcutActions)
              _ShortcutCaptureTile(
                action: action,
                title: _shortcutActionTitle(action),
                description: _shortcutActionDescription(action),
                icon: _shortcutActionIcon(action),
                isCapturing: _capturingAction == action,
                binding: _capturingAction == action
                    ? _capturedBinding
                    : shortcuts[action],
                capturedBinding: _capturingAction == action
                    ? _capturedBinding
                    : null,
                liveInput: _capturingAction == action ? _liveInput : null,
                platform: platform,
                onPressed: () => _startCapture(action, shortcuts[action]),
              ),
            const SizedBox(height: 18),
            // --- Built-in Shortcuts (read-only) ---
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                'Built-in',
                style: textTheme.titleSmall?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _BuiltInShortcutTile(
              icon: Icons.play_arrow_rounded,
              title: 'Play / Pause',
              description: 'Toggle playback',
              shortcutLabel: 'Space',
            ),
            _BuiltInShortcutTile(
              icon: Icons.skip_previous_rounded,
              title: 'Previous Track',
              description: 'Skip to previous track',
              shortcutLabel: platform == TargetPlatform.macOS
                  ? '←  or  Option+,'
                  : '←  or  Alt+,',
            ),
            _BuiltInShortcutTile(
              icon: Icons.skip_next_rounded,
              title: 'Next Track',
              description: 'Skip to next track',
              shortcutLabel: platform == TargetPlatform.macOS
                  ? '→  or  Option+.'
                  : '→  or  Alt+.',
            ),
            _BuiltInShortcutTile(
              icon: Icons.close_rounded,
              title: 'Dismiss Overlay',
              description: 'Close the topmost overlay or dialog',
              shortcutLabel: 'Esc',
            ),
          ],
        ),
      ),
    );
  }

  IconData _shortcutActionIcon(DesktopCommandAction action) {
    return switch (action) {
      DesktopCommandAction.openQuickSearch => Icons.search_rounded,
      DesktopCommandAction.focusSearch => Icons.manage_search_rounded,
      DesktopCommandAction.toggleQueue => Icons.queue_music_rounded,
      DesktopCommandAction.goHome => Icons.home_rounded,
      DesktopCommandAction.goLibrary => Icons.library_music_rounded,
      DesktopCommandAction.goSearch => Icons.search_rounded,
      DesktopCommandAction.goSettings => Icons.settings_rounded,
      DesktopCommandAction.toggleNowPlaying => Icons.music_note_rounded,
      DesktopCommandAction.playPause => Icons.play_arrow_rounded,
      DesktopCommandAction.nextTrack => Icons.skip_next_rounded,
      DesktopCommandAction.previousTrack => Icons.skip_previous_rounded,
      DesktopCommandAction.refreshLibrary => Icons.refresh_rounded,
      DesktopCommandAction.forceRescanLibrary => Icons.find_replace_rounded,
    };
  }

  String _shortcutActionTitle(DesktopCommandAction action) {
    return switch (action) {
      DesktopCommandAction.openQuickSearch => 'Quick Search',
      DesktopCommandAction.focusSearch => 'Focus Search',
      DesktopCommandAction.toggleQueue => 'Toggle Queue',
      DesktopCommandAction.goHome => 'Go to Home',
      DesktopCommandAction.goLibrary => 'Go to Library',
      DesktopCommandAction.goSearch => 'Go to Search',
      DesktopCommandAction.goSettings => 'Go to Settings',
      DesktopCommandAction.toggleNowPlaying => 'Toggle Now Playing',
      DesktopCommandAction.playPause => 'Play / Pause',
      DesktopCommandAction.nextTrack => 'Next Track',
      DesktopCommandAction.previousTrack => 'Previous Track',
      DesktopCommandAction.refreshLibrary => 'Refresh Library',
      DesktopCommandAction.forceRescanLibrary => 'Force Full Rescan',
    };
  }

  String _shortcutActionDescription(DesktopCommandAction action) {
    return switch (action) {
      DesktopCommandAction.openQuickSearch => 'Open the quick-search overlay',
      DesktopCommandAction.focusSearch =>
        'Navigate to search and focus the input',
      DesktopCommandAction.toggleQueue => 'Show or hide the playback queue',
      DesktopCommandAction.goHome => 'Navigate to the home screen',
      DesktopCommandAction.goLibrary => 'Navigate to the library',
      DesktopCommandAction.goSearch => 'Navigate to search',
      DesktopCommandAction.goSettings => 'Open settings',
      DesktopCommandAction.toggleNowPlaying => 'Expand or collapse now playing',
      DesktopCommandAction.playPause => 'Toggle playback',
      DesktopCommandAction.nextTrack => 'Skip to next track',
      DesktopCommandAction.previousTrack => 'Skip to previous track',
      DesktopCommandAction.refreshLibrary => 'Sync new changes to the library',
      DesktopCommandAction.forceRescanLibrary =>
        'Force a complete rescan of all library files',
    };
  }
}

// ---------------------------------------------------------------------------
// Configurable shortcut tile
// ---------------------------------------------------------------------------

class _ShortcutCaptureTile extends StatelessWidget {
  const _ShortcutCaptureTile({
    required this.action,
    required this.title,
    required this.description,
    required this.icon,
    required this.isCapturing,
    required this.binding,
    required this.capturedBinding,
    required this.liveInput,
    required this.platform,
    required this.onPressed,
  });

  final DesktopCommandAction action;
  final String title;
  final String description;
  final IconData icon;
  final bool isCapturing;
  final DesktopShortcutBinding? binding;
  final DesktopShortcutBinding? capturedBinding;

  /// Partially-held modifier string, e.g. "Ctrl+", shown while the user is
  /// building a combo but hasn't pressed the final key yet.
  final String? liveInput;
  final TargetPlatform platform;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // Subtitle: live preview during capture, description otherwise.
    final String subtitle;
    if (isCapturing && capturedBinding != null) {
      subtitle = 'Enter to save · Backspace to clear · Esc to cancel';
    } else if (isCapturing) {
      subtitle = 'Hold modifiers then press a key (e.g. Ctrl+Shift+F)';
    } else {
      subtitle = description;
    }

    // Button label progression:
    //   idle         → current binding or "Not Set"
    //   waiting      → "Waiting for new input…"
    //   modifiers held → "Ctrl+Shift+" (growing)
    //   full combo    → "Ctrl+Shift+F" (captured)
    final String buttonLabel;
    if (isCapturing && capturedBinding != null) {
      buttonLabel = capturedBinding!.formatLabel(platform);
    } else if (isCapturing && liveInput != null) {
      buttonLabel = '$liveInput+';
    } else if (isCapturing) {
      buttonLabel = 'Waiting for new input…';
    } else {
      buttonLabel = binding?.formatLabel(platform) ?? 'Not Set';
    }

    return Card(
      elevation: isCapturing ? 2 : 0,
      color: isCapturing
          ? colors.primaryContainer.withValues(alpha: 0.25)
          : null,
      child: ListTile(
        onTap: onPressed,
        leading: Icon(icon, color: colors.onSurfaceVariant, size: 22),
        title: Text(title, style: textTheme.bodyLarge),
        subtitle: Text(
          subtitle,
          style: textTheme.bodySmall?.copyWith(
            color: isCapturing ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
        trailing: isCapturing
            ? OutlinedButton(
                key: ValueKey<String>('desktopShortcut-${action.name}'),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: colors.primary, width: 2),
                  foregroundColor: colors.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: onPressed,
                child: Text(
                  buttonLabel,
                  style: textTheme.labelMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            : OutlinedButton(
                key: ValueKey<String>('desktopShortcut-${action.name}'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: onPressed,
                child: Text(
                  buttonLabel,
                  style: textTheme.labelMedium?.copyWith(
                    color: binding != null
                        ? colors.onSurface
                        : colors.onSurfaceVariant,
                  ),
                ),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Built-in (read-only) shortcut tile
// ---------------------------------------------------------------------------

class _BuiltInShortcutTile extends StatelessWidget {
  const _BuiltInShortcutTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.shortcutLabel,
  });

  final IconData icon;
  final String title;
  final String description;
  final String shortcutLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      child: ListTile(
        leading: Icon(
          icon,
          color: colors.onSurfaceVariant.withValues(alpha: 0.6),
          size: 22,
        ),
        title: Text(
          title,
          style: textTheme.bodyLarge?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          description,
          style: textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            shortcutLabel,
            style: textTheme.labelMedium?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
