import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Named command actions supported by the desktop shell.
enum DesktopCommandAction {
  focusSearch,
  openQuickSearch,
  toggleQueue,

  /// Escape: closes the top-most panel, overlay or dialog. The name predates
  /// that behaviour and is kept because saved bindings are keyed by it.
  toggleNowPlaying,
  goHome,
  goLibrary,
  goSearch,
  goSettings,
  playPause,
  nextTrack,
  previousTrack,
  refreshLibrary,
  forceRescanLibrary,
  speedUp,
  speedDown,
  speedReset,
  navigateBack,
  navigateForward,
}

@immutable
class DesktopShortcutBinding {
  const new({
    required this.key,
    this.primaryModifier = true,
    this.alt = false,
    this.shift = false,
  });

  final LogicalKeyboardKey key;
  final bool primaryModifier;
  final bool alt;
  final bool shift;

  @visibleForTesting
  ShortcutActivator toActivator(TargetPlatform platform) {
    final isApple = platform == TargetPlatform.macOS;
    return SingleActivator(
      key,
      meta: isApple && primaryModifier,
      control: !isApple && primaryModifier,
      alt: alt,
      shift: shift,
      includeRepeats: false,
    );
  }

  String formatLabel(TargetPlatform platform) {
    final isApple = platform == TargetPlatform.macOS;
    final parts = <String>[
      if (primaryModifier)
        if (isApple) 'Cmd' else 'Ctrl',
      if (alt)
        if (isApple) 'Option' else 'Alt',
      if (shift) 'Shift',
      _shortcutKeyLabel(key),
    ];
    return parts.join('+');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopShortcutBinding &&
          key == other.key &&
          primaryModifier == other.primaryModifier &&
          alt == other.alt &&
          shift == other.shift;

  @override
  int get hashCode => Object.hash(key, primaryModifier, alt, shift);
}

String _shortcutKeyLabel(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.digit1) return '1';
  if (key == LogicalKeyboardKey.digit2) return '2';
  if (key == LogicalKeyboardKey.digit3) return '3';
  if (key == LogicalKeyboardKey.digit4) return '4';
  if (key == LogicalKeyboardKey.digit5) return '5';
  if (key == LogicalKeyboardKey.digit6) return '6';
  if (key == LogicalKeyboardKey.digit7) return '7';
  if (key == LogicalKeyboardKey.digit8) return '8';
  if (key == LogicalKeyboardKey.digit9) return '9';
  final label = key.keyLabel.trim();
  if (label.isNotEmpty) {
    return label.toUpperCase();
  }
  return key.debugName ?? key.keyId.toRadixString(16);
}

const List<DesktopCommandAction> configurableDesktopShortcutActions =
    <DesktopCommandAction>[
      DesktopCommandAction.openQuickSearch,
      DesktopCommandAction.focusSearch,
      DesktopCommandAction.toggleQueue,
      DesktopCommandAction.goHome,
      DesktopCommandAction.goLibrary,
      DesktopCommandAction.goSearch,
      DesktopCommandAction.goSettings,
      DesktopCommandAction.navigateBack,
      DesktopCommandAction.navigateForward,
      DesktopCommandAction.refreshLibrary,
      DesktopCommandAction.forceRescanLibrary,
      DesktopCommandAction.speedUp,
      DesktopCommandAction.speedDown,
      DesktopCommandAction.speedReset,
    ];

Map<DesktopCommandAction, DesktopShortcutBinding?>
defaultDesktopShortcutBindings() {
  return Map<DesktopCommandAction, DesktopShortcutBinding?>.unmodifiable(
    LinkedHashMap<DesktopCommandAction, DesktopShortcutBinding?>.from(
      <DesktopCommandAction, DesktopShortcutBinding?>{
        DesktopCommandAction.openQuickSearch: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.keyF,
        ),
        DesktopCommandAction.focusSearch: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.keyK,
        ),
        DesktopCommandAction.toggleQueue: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.keyJ,
        ),
        DesktopCommandAction.goHome: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.digit1,
        ),
        DesktopCommandAction.goLibrary: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.digit2,
        ),
        DesktopCommandAction.goSearch: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.digit3,
        ),
        DesktopCommandAction.goSettings: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.digit4,
        ),
        // Browser conventions: Cmd+[ / Cmd+] on macOS, Alt+Left / Alt+Right
        // elsewhere.
        DesktopCommandAction.navigateBack: _isApplePlatform
            ? const DesktopShortcutBinding(key: LogicalKeyboardKey.bracketLeft)
            : const DesktopShortcutBinding(
                key: LogicalKeyboardKey.arrowLeft,
                primaryModifier: false,
                alt: true,
              ),
        DesktopCommandAction.navigateForward: _isApplePlatform
            ? const DesktopShortcutBinding(key: LogicalKeyboardKey.bracketRight)
            : const DesktopShortcutBinding(
                key: LogicalKeyboardKey.arrowRight,
                primaryModifier: false,
                alt: true,
              ),
        DesktopCommandAction.refreshLibrary: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.keyR,
        ),
        DesktopCommandAction.forceRescanLibrary: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.keyR,
          shift: true,
        ),
        // Unshifted punctuation keeps the logical key stable across layouts
        // (Shift+. reports '>' on many keyboards).
        DesktopCommandAction.speedUp: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.period,
        ),
        DesktopCommandAction.speedDown: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.comma,
        ),
        DesktopCommandAction.speedReset: const DesktopShortcutBinding(
          key: LogicalKeyboardKey.digit0,
        ),
      },
    ),
  );
}

bool get _isApplePlatform => defaultTargetPlatform == TargetPlatform.macOS;

const String _desktopShortcutStorageKey = 'navis.desktop.shortcut_bindings.v1';
const FlutterSecureStorage _desktopShortcutStorage = FlutterSecureStorage();
String? _desktopShortcutSessionFallback;
bool _didLogShortcutReadFallbackWarning = false;
bool _didLogShortcutWriteFallbackWarning = false;

Future<String?> _readPersistedDesktopShortcutBindings() async {
  try {
    final stored = await _desktopShortcutStorage.read(
      key: _desktopShortcutStorageKey,
    );
    return stored ?? _desktopShortcutSessionFallback;
  } on Object catch (error) {
    if (!_didLogShortcutReadFallbackWarning) {
      _didLogShortcutReadFallbackWarning = true;
      AppLogger.warning(
        'Desktop shortcut read failed; using session fallback: $error',
      );
    }
    return _desktopShortcutSessionFallback;
  }
}

Future<void> _writePersistedDesktopShortcutBindings(String? raw) async {
  _desktopShortcutSessionFallback = raw;
  try {
    if (raw == null || raw.trim().isEmpty) {
      await _desktopShortcutStorage.delete(key: _desktopShortcutStorageKey);
      return;
    }
    await _desktopShortcutStorage.write(
      key: _desktopShortcutStorageKey,
      value: raw,
    );
  } on Object catch (error) {
    if (!_didLogShortcutWriteFallbackWarning) {
      _didLogShortcutWriteFallbackWarning = true;
      AppLogger.warning(
        'Desktop shortcut write failed; using session fallback: $error',
      );
    }
  }
}

bool _shortcutMapsEqual(
  Map<DesktopCommandAction, DesktopShortcutBinding?> a,
  Map<DesktopCommandAction, DesktopShortcutBinding?> b,
) {
  if (a.length != b.length) {
    return false;
  }
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> _shortcutBindingToJsonObject(
  DesktopShortcutBinding value,
) {
  return <String, Object?>{
    'keyId': value.key.keyId,
    'primaryModifier': value.primaryModifier,
    'alt': value.alt,
    'shift': value.shift,
  };
}

DesktopShortcutBinding? _shortcutBindingFromJsonObject(Object? value) {
  if (value is! Map<String, Object?>) {
    return null;
  }

  final rawKeyId = value['keyId'];
  if (rawKeyId is! int) {
    return null;
  }

  final key = LogicalKeyboardKey.findKeyByKeyId(rawKeyId);
  if (key == null) {
    return null;
  }

  final primaryModifier = value['primaryModifier'];
  final alt = value['alt'];
  final shift = value['shift'];
  return DesktopShortcutBinding(
    key: key,
    primaryModifier: primaryModifier is! bool || primaryModifier,
    alt: alt is bool && alt,
    shift: shift is bool && shift,
  );
}

String? encodeDesktopShortcutBindings(
  Map<DesktopCommandAction, DesktopShortcutBinding?> shortcuts,
) {
  final defaults = defaultDesktopShortcutBindings();
  if (_shortcutMapsEqual(shortcuts, defaults)) {
    return null;
  }

  final encoded = <String, Object?>{};
  for (final action in configurableDesktopShortcutActions) {
    final binding = shortcuts[action];
    encoded[action.name] = binding == null
        ? null
        : _shortcutBindingToJsonObject(binding);
  }
  return jsonEncode(encoded);
}

Map<DesktopCommandAction, DesktopShortcutBinding?>
decodeDesktopShortcutBindings(String? raw) {
  final resolved =
      LinkedHashMap<DesktopCommandAction, DesktopShortcutBinding?>.from(
        defaultDesktopShortcutBindings(),
      );
  if (raw == null || raw.trim().isEmpty) {
    return Map<DesktopCommandAction, DesktopShortcutBinding?>.unmodifiable(
      resolved,
    );
  }

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return Map<DesktopCommandAction, DesktopShortcutBinding?>.unmodifiable(
        resolved,
      );
    }

    for (final action in configurableDesktopShortcutActions) {
      if (!decoded.containsKey(action.name)) {
        continue;
      }
      final value = decoded[action.name];
      if (value == null) {
        resolved[action] = null;
        continue;
      }
      final binding = _shortcutBindingFromJsonObject(
        value is Map ? value.cast<String, Object?>() : value,
      );
      if (binding != null) {
        resolved[action] = binding;
      }
    }
  } on FormatException {
    return Map<DesktopCommandAction, DesktopShortcutBinding?>.unmodifiable(
      resolved,
    );
  }

  return Map<DesktopCommandAction, DesktopShortcutBinding?>.unmodifiable(
    resolved,
  );
}

class DesktopShortcutBindingsNotifier
    extends Notifier<Map<DesktopCommandAction, DesktopShortcutBinding?>> {
  bool _didScheduleHydration = false;

  @override
  Map<DesktopCommandAction, DesktopShortcutBinding?> build() {
    if (!_didScheduleHydration) {
      _didScheduleHydration = true;
      unawaited(_hydratePersistedBindings());
    }

    return defaultDesktopShortcutBindings();
  }

  void setBinding(
    DesktopCommandAction action,
    DesktopShortcutBinding? binding,
  ) {
    final updated =
        LinkedHashMap<DesktopCommandAction, DesktopShortcutBinding?>.from(
          state,
        );
    if (binding != null) {
      for (final entry in updated.entries.toList()) {
        if (entry.key != action && entry.value == binding) {
          updated[entry.key] = null;
        }
      }
    }
    updated[action] = binding;
    final nextState =
        Map<DesktopCommandAction, DesktopShortcutBinding?>.unmodifiable(
          updated,
        );
    state = nextState;
    AppLogger.debug(
      '[ACP_INPUT] desktop shortcuts updated: ${action.name}=${binding?.key.debugName ?? 'disabled'}',
    );
    _persistBindings(nextState);
  }

  void resetDefaults() {
    final nextState = defaultDesktopShortcutBindings();
    state = nextState;
    AppLogger.debug('[ACP_INPUT] desktop shortcuts reset to defaults');
    _persistBindings(nextState);
  }

  void _persistBindings(
    Map<DesktopCommandAction, DesktopShortcutBinding?> bindings,
  ) {
    final encoded = encodeDesktopShortcutBindings(bindings);
    unawaited(() async {
      await _writePersistedDesktopShortcutBindings(encoded);
    }());
  }

  Future<void> _hydratePersistedBindings() async {
    final persisted = await _readPersistedDesktopShortcutBindings();
    final decoded = decodeDesktopShortcutBindings(persisted);
    AppLogger.debug(
      '[ACP_INPUT] desktop shortcuts hydrated (persisted=${persisted != null && persisted.isNotEmpty})',
    );
    if (!_shortcutMapsEqual(state, decoded)) {
      state = decoded;
    }
  }
}

final desktopShortcutBindingsProvider =
    NotifierProvider<
      DesktopShortcutBindingsNotifier,
      Map<DesktopCommandAction, DesktopShortcutBinding?>
    >(DesktopShortcutBindingsNotifier.new);

bool desktopCommandBlockedByTextInput() {
  final focusNode = FocusManager.instance.primaryFocus;
  if (focusNode == null) {
    return false;
  }
  final focusContext = focusNode.context;
  if (focusContext == null) {
    return false;
  }
  // Check if the focused widget itself is an EditableText (covers TextField,
  // TextFormField, CupertinoTextField, and any custom wrapper).
  if (focusContext.widget is EditableText) {
    return true;
  }
  // Walk up the tree to catch EditableText hosted inside composite widgets.
  return focusContext.findAncestorStateOfType<EditableTextState>() != null;
}

bool _isBindingMatchForEvent(
  KeyDownEvent event,
  DesktopShortcutBinding binding,
  TargetPlatform platform,
) {
  if (event.logicalKey != binding.key) {
    return false;
  }
  final keyboard = HardwareKeyboard.instance;
  final isApple = platform == TargetPlatform.macOS;
  final primaryModifierPressed = isApple
      ? keyboard.isMetaPressed
      : keyboard.isControlPressed;
  return primaryModifierPressed == binding.primaryModifier &&
      keyboard.isAltPressed == binding.alt &&
      keyboard.isShiftPressed == binding.shift;
}

DesktopCommandAction? matchDesktopCommandActionForKeyDownEvent(
  KeyDownEvent event,
  TargetPlatform platform, {
  Map<DesktopCommandAction, DesktopShortcutBinding?>? shortcutBindings,
}) {
  final bindings = shortcutBindings ?? defaultDesktopShortcutBindings();
  for (final action in configurableDesktopShortcutActions) {
    final binding = bindings[action];
    if (binding == null) {
      continue;
    }
    if (_isBindingMatchForEvent(event, binding, platform)) {
      return action;
    }
  }
  return null;
}

/// Matches ALL desktop commands including built-in (non-configurable) ones.
///
/// Returns the matched action or `null`. This is the single entry-point for
/// the global hardware-keyboard handler.
DesktopCommandAction? matchAnyDesktopCommandForKeyEvent(
  KeyDownEvent event,
  TargetPlatform platform, {
  required bool enableShortcuts,
  required bool enableEscapeOverlay,
  Map<DesktopCommandAction, DesktopShortcutBinding?>? shortcutBindings,
}) {
  final key = event.logicalKey;
  final keyboard = HardwareKeyboard.instance;
  final noModifiers =
      !keyboard.isControlPressed &&
      !keyboard.isMetaPressed &&
      !keyboard.isAltPressed &&
      !keyboard.isShiftPressed;

  // ESC — always checked when escape overlay priority is enabled.
  if (enableEscapeOverlay && key == LogicalKeyboardKey.escape && noModifiers) {
    return DesktopCommandAction.toggleNowPlaying;
  }

  if (!enableShortcuts) {
    return null;
  }

  // Built-in transport shortcuts (no modifiers).
  if (noModifiers) {
    if (key == LogicalKeyboardKey.space) {
      return DesktopCommandAction.playPause;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      return DesktopCommandAction.nextTrack;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      return DesktopCommandAction.previousTrack;
    }
  }
  // Alt-based transport alternates.
  if (keyboard.isAltPressed &&
      !keyboard.isControlPressed &&
      !keyboard.isMetaPressed &&
      !keyboard.isShiftPressed) {
    if (key == LogicalKeyboardKey.period) {
      return DesktopCommandAction.nextTrack;
    }
    if (key == LogicalKeyboardKey.comma) {
      return DesktopCommandAction.previousTrack;
    }
  }

  // Configurable shortcuts.
  return matchDesktopCommandActionForKeyDownEvent(
    event,
    platform,
    shortcutBindings: shortcutBindings,
  );
}

/// Whether the given action should be suppressed when a text field has focus.
bool isTextSensitiveDesktopCommand(DesktopCommandAction action) {
  return action == DesktopCommandAction.playPause ||
      action == DesktopCommandAction.nextTrack ||
      action == DesktopCommandAction.previousTrack ||
      // Modified arrows move the caret by word in text fields.
      action == DesktopCommandAction.navigateBack ||
      action == DesktopCommandAction.navigateForward;
}
