import 'dart:async';

import 'package:navis/src/features/equalizer/presentation/eq_screen.dart';
import 'package:navis/src/features/library/presentation/detail_load_states.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:navis/src/common_widgets/external_album_card.dart';

import 'dart:io';

import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_panel.dart';
import 'package:navis/src/features/player/presentation/playback_quick_actions.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/common_widgets/navis_tooltip.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/features/downloads/presentation/downloads_screen.dart';
import 'package:path/path.dart' as p;

class DiagnosticsPresentationUnavailable implements Exception {
  const new();
}

/// The mounted surface exists, but the requested step or card index is not
/// one it has.
class DiagnosticsPresentationOutOfRange implements Exception {
  const new(this.count);

  /// How many steps or cards the surface has.
  final int count;
}

/// What tapping a release card did. [outcome] is `albumPage` (the album page
/// it opened shows the album), `failed` (that page could not load it and
/// offers Retry and a search), `loading` (still loading at the end of the
/// wait), `unknown` (an album page showing neither at the end of the wait),
/// `otherPage` (the app left the album page) or `none` (the tap did not
/// navigate).
class DiagnosticsReleaseCardResult {
  const new({required this.outcome, required this.location});

  final String outcome;

  /// The route after the tap.
  final String? location;

  Map<String, Object?> toJson() => <String, Object?>{
    'outcome': outcome,
    'location': location,
  };
}

class DiagnosticsPresentationStatus {
  const new({
    required this.logicalWidth,
    required this.logicalHeight,
    required this.devicePixelRatio,
    required this.screenshotReady,
  });

  final double logicalWidth;
  final double logicalHeight;
  final double devicePixelRatio;
  final bool screenshotReady;

  Map<String, Object?> toJson() => <String, Object?>{
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'devicePixelRatio': devicePixelRatio,
    'screenshotReady': screenshotReady,
  };
}

class DiagnosticsScreenshot {
  const new({
    required this.artifact,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.pixelRatio,
    required this.byteCount,
    required this.sha256Digest,
  });

  final String artifact;
  final double logicalWidth;
  final double logicalHeight;
  final int pixelWidth;
  final int pixelHeight;
  final double pixelRatio;
  final int byteCount;
  final String sha256Digest;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': 'captured',
    'artifact': artifact,
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'pixelWidth': pixelWidth,
    'pixelHeight': pixelHeight,
    'pixelRatio': pixelRatio,
    'byteCount': byteCount,
    'sha256': sha256Digest,
  };
}

/// Where [DiagnosticsPresentationController.scrollPrimary] left the page.
class DiagnosticsScrollResult {
  const new({
    required this.pixels,
    required this.maxScrollExtent,
    required this.viewportDimension,
  });

  final double pixels;
  final double maxScrollExtent;
  final double viewportDimension;

  Map<String, Object?> toJson() => <String, Object?>{
    'pixels': pixels,
    'maxScrollExtent': maxScrollExtent,
    'viewportDimension': viewportDimension,
  };
}

class DiagnosticsPresentationController {
  new({required Directory artifactRoot, this.frameWaiter})
    : _artifactRoot = Directory(p.normalize(p.absolute(artifactRoot.path)));

  static final RegExp _validLabel = RegExp(r'^[a-z0-9][a-z0-9_-]{0,47}$');
  static const double _capturePixelRatio = 1;
  static const tooltipTargets = <String, String>{
    'favorite': 'desktopPlayerFavoriteButton',
    'lyrics': 'desktopPlayerLyricsButton',
    'queue': 'desktopQueueButton',
    'miniPlayer': 'desktopPlayerMiniPlayerButton',
  };
  static const _tooltipPointerDevice = 904;
  static const libraryActions = {
    'openFirstAlbum',
    'nextLikedAlbums',
    'toggleFirstRadioStation',
    'weeklyPlay',
    'weeklyLastRow',
  };
  static const trackActions = {
    'scrollToLast',
    'revealFirst',
    'more',
    'download',
    'downloadedTab',
    'downloadsSettingsTab',
    'downloadsQueueTab',
    'customFolderOff',
    'confirmCustomFolderOff',
    'dragFirstToLast',
    'downloadQuality320',
    'downloadQualityAlwaysUse',
    'downloadQualityAlwaysAsk',
  };

  static const artistActions = {'play', 'shuffle', 'cancel', 'queue'};

  /// Playback settings switches the diagnostics API may flip, by widget key.
  static const playbackSettingToggles = <String, String>{
    'scrobble': 'playbackSettingsScrobbleToggle',
  };

  Future<void> activateArtistControl({required String action}) async {
    if (!artistActions.contains(action)) throw const FormatException();
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final key = action == 'queue'
        ? 'desktopQueueButton'
        : action == 'play' || action == 'shuffle'
        ? 'artist-$action'
        : 'artist-playback-$action';
    final element = _findElement(
      root,
      (element) => element.widget.key == ValueKey<String>(key),
    );
    final widget = element?.widget;
    final callback = switch (widget) {
      ButtonStyleButton(:final onPressed) => onPressed,
      Semantics(:final properties) => properties.onTap,
      _ => null,
    };
    if (callback == null) throw const DiagnosticsPresentationUnavailable();
    callback();
    await waitForFrame();
  }

  /// Exercises mounted track controls only; the server gates this to clones.
  Future<void> activateTrackControl({required String action}) async {
    if (!trackActions.contains(action)) throw const FormatException();
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    if (action == 'downloadedTab' ||
        action == 'downloadsSettingsTab' ||
        action == 'downloadsQueueTab') {
      final downloads = _findElement(
        root,
        (element) =>
            element.widget is DownloadsScreen &&
            ModalRoute.of(element)?.isCurrent != false,
      );
      final tabs = downloads == null
          ? null
          : _findElement(downloads, (element) => element.widget is TabBar);
      final controller = (tabs?.widget as TabBar?)?.controller;
      if (controller == null) throw const DiagnosticsPresentationUnavailable();
      controller.animateTo(switch (action) {
        'downloadsQueueTab' => 0,
        'downloadedTab' => 1,
        _ => 2,
      });
    } else if (action == 'customFolderOff') {
      final tile = _findElement(
        root,
        (element) =>
            element.widget.key ==
                const ValueKey<String>('downloadsCustomFolderSwitch') &&
            ModalRoute.of(element)?.isCurrent != false,
      );
      final widget = tile?.widget as SwitchListTile?;
      // Only ever off: turning the folder on opens the system folder picker.
      final onChanged = widget?.value == true ? widget?.onChanged : null;
      if (onChanged == null) throw const DiagnosticsPresentationUnavailable();
      onChanged(false);
    } else if (action == 'downloadQuality320') {
      // The picker's 320 kbps row (the picker is shown by 'download').
      final row = _findElement(
        root,
        (element) =>
            element.widget.key == const ValueKey<String>('downloadQuality:320'),
      );
      final onTap = (row?.widget as ListTile?)?.onTap;
      if (onTap == null) throw const DiagnosticsPresentationUnavailable();
      onTap();
    } else if (action == 'downloadQualityAlwaysUse' ||
        action == 'downloadQualityAlwaysAsk') {
      // The one-time "always download in this quality?" answers.
      final button = _findElement(
        root,
        (element) => element.widget.key == ValueKey<String>(action),
      );
      final onPressed = (button?.widget as ButtonStyleButton?)?.onPressed;
      if (onPressed == null) throw const DiagnosticsPresentationUnavailable();
      onPressed();
    } else if (action == 'confirmCustomFolderOff') {
      final button = _findElement(
        root,
        (element) =>
            element.widget.key ==
            const ValueKey<String>('downloadsCustomFolderDisableConfirm'),
      );
      final onPressed = (button?.widget as ButtonStyleButton?)?.onPressed;
      if (onPressed == null) throw const DiagnosticsPresentationUnavailable();
      onPressed();
    } else {
      final rows = <Element>[];
      void collect(Element element) {
        if (element.widget is Offstage &&
            (element.widget as Offstage).offstage) {
          return;
        }
        if (element.widget is AdaptiveTrackRow &&
            ModalRoute.of(element)?.isCurrent != false) {
          rows.add(element);
        }
        element.visitChildElements(collect);
      }

      collect(root);
      if (rows.isEmpty) throw const DiagnosticsPresentationUnavailable();
      if (action == 'revealFirst') {
        await Scrollable.ensureVisible(rows.first, alignment: .2);
      } else if (action == 'scrollToLast') {
        final scrollable = Scrollable.maybeOf(rows.last);
        if (scrollable == null) {
          throw const DiagnosticsPresentationUnavailable();
        }
        await scrollable.position.animateTo(
          scrollable.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else if (action == 'dragFirstToLast') {
        final handle = _findElement(
          rows.first,
          (element) => element.widget is ReorderableDragStartListener,
        );
        final box = handle?.findRenderObject();
        final last = rows.last.findRenderObject();
        if (box is! RenderBox || last is! RenderBox) {
          throw const DiagnosticsPresentationUnavailable();
        }
        final start = box.localToGlobal(box.size.center(Offset.zero));
        final end = Offset(
          start.dx,
          last.localToGlobal(Offset(0, last.size.height)).dy + 8,
        );
        final binding = GestureBinding.instance;
        final viewId = View.of(root).viewId;
        const pointer = 9281;
        binding.handlePointerEvent(
          PointerDownEvent(pointer: pointer, position: start, viewId: viewId),
        );
        var previous = start;
        try {
          for (var step = 1; step <= 12; step++) {
            final position = Offset.lerp(start, end, step / 12)!;
            binding.handlePointerEvent(
              PointerMoveEvent(
                pointer: pointer,
                position: position,
                delta: position - previous,
                buttons: kPrimaryButton,
                timeStamp: Duration(milliseconds: step * 30),
                viewId: viewId,
              ),
            );
            previous = position;
            await waitForFrame();
          }
        } finally {
          binding.handlePointerEvent(
            PointerUpEvent(pointer: pointer, position: end, viewId: viewId),
          );
        }
      } else if (action == 'download') {
        final icon = _findElement(
          rows.first,
          (element) => element.widget is SongDownloadStatusIcon,
        );
        final callback = (icon?.widget as SongDownloadStatusIcon?)?.onDownload;
        if (callback == null) throw const DiagnosticsPresentationUnavailable();
        callback();
      } else {
        final button = _findElement(
          rows.first,
          (element) =>
              element.widget is IconButton &&
              (element.widget as IconButton).icon is Icon &&
              ((element.widget as IconButton).icon as Icon).icon ==
                  Icons.more_vert,
        );
        final callback = (button?.widget as IconButton?)?.onPressed;
        if (callback == null) throw const DiagnosticsPresentationUnavailable();
        callback();
      }
    }
    await waitForFrame();
  }

  static bool isValidLabel(String label) => _validLabel.hasMatch(label);

  final Directory _artifactRoot;
  final Future<void> Function()? frameWaiter;
  final GlobalKey _boundaryKey = GlobalKey(
    debugLabel: 'diagnosticsPresentationBoundary',
  );
  bool _appReady = false;
  bool _tooltipPointerAdded = false;
  SemanticsHandle? _tooltipSemantics;

  bool get appReady => _appReady;

  void markAppReady() {
    _appReady = true;
  }

  Future<Map<String, Object>?> activateEqualizerControl({
    required String action,
    int index = 0,
    String? value,
    double dx = 0,
    double dy = 0,
  }) async {
    if (!dx.isFinite || !dy.isFinite || dx.abs() > 10000 || dy.abs() > 10000) {
      throw const FormatException(
        'EQ gesture coordinates must be finite and bounded.',
      );
    }
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final editor = _findElement(root, (e) => e.widget is EqualizerScreen);
    if (editor is! StatefulElement || editor.state is! EqualizerScreenState) {
      throw const DiagnosticsPresentationUnavailable();
    }
    final screen = editor.state as EqualizerScreenState;
    // Controller endpoints can change the curve without waiting for a frame;
    // mounted controls must act on the rebuilt page, not a stale curve.
    await waitForFrame();
    if (!editor.mounted) throw const DiagnosticsPresentationUnavailable();
    switch (action) {
      case 'profileGraph':
        return screen.profileGraph(index);
      case 'selectBand':
        screen.selectBand(index);
      case 'dragBand':
        screen.dragBand(index, dx, dy);
        await screen.flushGraphEdits();
      case 'cancelDrag':
        screen.dragBand(index, dx, dy, cancel: true);
        await screen.flushGraphEdits();
      case 'edit':
        screen.selectBand(index);
        screen.editNumber('gain');
      case 'frequency' || 'gain' || 'q' || 'preamp':
        screen.editNumber(action);
        if (value != null) await screen.typeNumber(value);
      case 'apply' || 'done':
        await screen.finishNumber();
      case 'cancel':
        await screen.cancelNumber();
      default:
        throw const FormatException('Unknown EQ presentation action.');
    }
    await waitForFrame();
    return null;
  }

  Element _boundaryElement() {
    final boundary = _boundaryKey.currentContext;
    if (boundary is! Element) throw const DiagnosticsPresentationUnavailable();
    return boundary;
  }

  /// Opens only the phone Now Playing settings sheet (volume and Sound)
  /// through its production button.
  Future<void> openNowPlayingSettingsSheet() async {
    final root = _boundaryElement();
    final settingsAction = _findElement(
      root,
      (element) =>
          element.widget.key == const ValueKey('nowPlayingSettingsAction') &&
          element.widget is IconButton,
    );
    final callback = (settingsAction?.widget as IconButton?)?.onPressed;
    if (callback == null) throw const DiagnosticsPresentationUnavailable();
    callback();
    await waitForFrame();
    if (!root.mounted) throw const DiagnosticsPresentationUnavailable();
    final sheet = _findElement(
      root,
      (element) =>
          element.widget.key == const ValueKey('nowPlayingSettingsSheet'),
    );
    if (sheet == null) throw const DiagnosticsPresentationUnavailable();
  }

  Future<void> revealPlaybackAdjustments({required bool open}) async {
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    if (open) {
      final settingsAction = _findElement(
        root,
        (element) =>
            element.widget.key == const ValueKey('nowPlayingSettingsAction') &&
            element.widget is IconButton,
      );
      (settingsAction?.widget as IconButton?)?.onPressed?.call();
      await waitForFrame();
      final entry = _findElement(
        root,
        (element) =>
            element.widget.key ==
                const ValueKey('playbackAdjustmentEntryPoint') &&
            element.widget is ListTile,
      );
      final callback = (entry?.widget as ListTile?)?.onTap;
      if (callback == null) throw const DiagnosticsPresentationUnavailable();
      callback();
      await waitForFrame();
    }
    final panel = _findElement(
      root,
      (element) => element.widget is PlaybackAdjustmentPanel,
    );
    if (panel == null) throw const DiagnosticsPresentationUnavailable();
    await Scrollable.ensureVisible(panel, alignment: 0);
    await waitForFrame();
  }

  /// Presses the first visible player Speed button through its production
  /// callback and reports whether the panel opened as a popover or a sheet.
  Future<String> openPlaybackQuickPanel({String target = 'speed'}) async {
    await pressPlayerQuickButton(target: target);
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final panelKey = ValueKey<String>(
      target == 'equalizer'
          ? 'equalizerQuickPanel'
          : 'playbackAdjustmentQuickPanel',
    );
    final panel = _findElement(
      root,
      (element) => element.widget.key == panelKey,
    );
    if (panel == null) throw const DiagnosticsPresentationUnavailable();
    final popover = _findElement(
      root,
      (element) =>
          element.widget.key ==
          const ValueKey<String>('desktopAnchoredPopover'),
    );
    return popover == null ? 'sheet' : 'popover';
  }

  /// Presses the first visible player Speed (`speed`) or Equalizer
  /// (`equalizer`) quick button through its production callback.
  Future<void> pressPlayerQuickButton({required String target}) async {
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final button = _findElement(
      root,
      (element) =>
          (target == 'equalizer'
              ? element.widget is EqualizerQuickButton
              : element.widget is PlaybackSpeedQuickButton) &&
          _isOnstage(element),
    );
    final iconButton = button == null
        ? null
        : _findElement(button, (element) => element.widget is IconButton);
    final callback = (iconButton?.widget as IconButton?)?.onPressed;
    if (callback == null) throw const DiagnosticsPresentationUnavailable();
    callback();
    await waitForFrame();
  }

  /// Chooses a preset in the mounted mini-EQ dropdown (`eq-quick-preset`)
  /// through its production selection callback.
  Future<void> selectQuickEqualizerPreset(String id) async {
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final picker = _findElement(
      root,
      (element) =>
          element.widget.key == const ValueKey<String>('eq-quick-preset') &&
          element.widget is DropdownMenu<String>,
    );
    final menu = picker?.widget as DropdownMenu<String>?;
    final available =
        menu?.enabled == true &&
        menu!.dropdownMenuEntries.any(
          (entry) => entry.value == id && entry.enabled,
        );
    final callback = menu?.onSelected;
    if (!available || callback == null) {
      throw const DiagnosticsPresentationUnavailable();
    }
    callback(id);
    await waitForFrame();
  }

  /// Presses the mounted "Open Equalizer" action of a quick panel or card.
  Future<void> openEqualizerFromQuickPanel() async {
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final action = _findElement(
      root,
      (element) =>
          element.widget.key == const ValueKey<String>('eq-quick-open-page') &&
          element.widget is ButtonStyleButton,
    );
    final callback = (action?.widget as ButtonStyleButton?)?.onPressed;
    if (callback == null) throw const DiagnosticsPresentationUnavailable();
    callback();
    await waitForFrame();
  }

  /// Visible player quick controls with their enabled state and, for Speed,
  /// the multiplier label shown instead of the icon.
  List<Map<String, Object?>> playbackQuickControls() {
    final root = _boundaryKey.currentContext;
    if (root is! Element) return const [];
    final controls = <Map<String, Object?>>[];
    void visit(Element element) {
      final widget = element.widget;
      if ((widget is PlaybackSpeedQuickButton ||
              widget is EqualizerQuickButton) &&
          _isOnstage(element)) {
        final iconButton = _findElement(
          element,
          (child) => child.widget is IconButton,
        );
        final label = _findElement(
          element,
          (child) =>
              child.widget.key ==
              const ValueKey<String>('playbackSpeedQuickLabel'),
        );
        if (iconButton != null) {
          controls.add(<String, Object?>{
            'key': switch (widget.key) {
              ValueKey<String>(:final value) => value,
              _ => null,
            },
            'kind': widget is PlaybackSpeedQuickButton ? 'speed' : 'equalizer',
            'enabled': (iconButton.widget as IconButton).onPressed != null,
            'label': (label?.widget as Text?)?.data,
          });
        }
        return;
      }
      element.visitChildElements(visit);
    }

    visit(root);
    return controls;
  }

  /// Sends [binding] through [HardwareKeyboard] so the shell's production
  /// global shortcut handler receives the same key sequence as a keyboard.
  Future<void> sendShortcut(
    DesktopShortcutBinding binding,
    TargetPlatform platform,
  ) async {
    final isApple = platform == TargetPlatform.macOS;
    final modifiers = <(PhysicalKeyboardKey, LogicalKeyboardKey)>[
      if (binding.primaryModifier && isApple)
        (PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft)
      else if (binding.primaryModifier)
        (PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft),
      if (binding.alt)
        (PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft),
      if (binding.shift)
        (PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft),
    ];
    final physical =
        _shortcutPhysicalKeys[binding.key] ??
        PhysicalKeyboardKey(binding.key.keyId);
    final keyboard = HardwareKeyboard.instance;
    final timeStamp = Duration(
      microseconds: DateTime.now().microsecondsSinceEpoch,
    );
    for (final (physicalKey, logicalKey) in modifiers) {
      keyboard.handleKeyEvent(
        KeyDownEvent(
          physicalKey: physicalKey,
          logicalKey: logicalKey,
          timeStamp: timeStamp,
        ),
      );
    }
    keyboard.handleKeyEvent(
      KeyDownEvent(
        physicalKey: physical,
        logicalKey: binding.key,
        timeStamp: timeStamp,
      ),
    );
    keyboard.handleKeyEvent(
      KeyUpEvent(
        physicalKey: physical,
        logicalKey: binding.key,
        timeStamp: timeStamp,
      ),
    );
    for (final (physicalKey, logicalKey) in modifiers.reversed) {
      keyboard.handleKeyEvent(
        KeyUpEvent(
          physicalKey: physicalKey,
          logicalKey: logicalKey,
          timeStamp: timeStamp,
        ),
      );
    }
    await waitForFrame();
  }

  static final _shortcutPhysicalKeys =
      <LogicalKeyboardKey, PhysicalKeyboardKey>{
        LogicalKeyboardKey.period: PhysicalKeyboardKey.period,
        LogicalKeyboardKey.comma: PhysicalKeyboardKey.comma,
        LogicalKeyboardKey.digit0: PhysicalKeyboardKey.digit0,
      };

  bool _isOnstage(Element element) {
    var visible = true;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Offstage && widget.offstage) {
        visible = false;
        return false;
      }
      return true;
    });
    return visible;
  }

  Future<void> activateLibraryControl({required String action}) async {
    if (!libraryActions.contains(action)) throw const FormatException();
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    bool onstage(Element element) {
      var visible = true;
      element.visitAncestorElements((ancestor) {
        final widget = ancestor.widget;
        if (widget is Offstage && widget.offstage) {
          visible = false;
          return false;
        }
        return true;
      });
      return visible;
    }

    VoidCallback? callback;
    if (action == 'openFirstAlbum') {
      final element = _findElement(
        root,
        (element) =>
            element.widget.key == const ValueKey('albumCardTapTarget') &&
            element.widget is InkWell &&
            onstage(element),
      );
      callback = (element?.widget as InkWell?)?.onTap;
    } else if (action == 'weeklyPlay') {
      // The weekly playlist page's own Play button.
      final element = _findElement(
        root,
        (element) =>
            element.widget.key == const ValueKey<String>('weeklyPlayButton') &&
            onstage(element),
      );
      callback = switch (element?.widget) {
        ButtonStyleButton(:final onPressed) => onPressed,
        IconButton(:final onPressed) => onPressed,
        _ => null,
      };
    } else if (action == 'weeklyLastRow') {
      // The last weekly track that can be played, through its row's own tap.
      var lastIndex = -1;
      root.visitChildElements((child) {
        void visit(Element element) {
          final key = element.widget.key;
          if (key is ValueKey<String> &&
              key.value.startsWith('weekly-row-') &&
              onstage(element)) {
            final index = int.tryParse(key.value.substring(11)) ?? -1;
            final row = _findElement(
              element,
              (row) => row.widget is AdaptiveTrackRow,
            );
            final onTap = (row?.widget as AdaptiveTrackRow?)?.onTap;
            if (onTap != null && index > lastIndex) {
              lastIndex = index;
              callback = onTap;
            }
          }
          element.visitChildElements(visit);
        }

        visit(child);
      });
    } else if (action == 'toggleFirstRadioStation') {
      // The card's own tap callback plays the station, or stops it when it
      // is already playing.
      final card = _findElement(root, (element) {
        final key = element.widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('radioStation-') &&
            onstage(element);
      });
      final target = card == null
          ? null
          : _findElement(card, (element) => element.widget is InkWell);
      callback = (target?.widget as InkWell?)?.onTap;
    } else {
      final shelf = _findElement(
        root,
        (element) =>
            element.widget.key == const ValueKey('liked-albums-shelf') &&
            onstage(element),
      );
      final button = shelf == null
          ? null
          : _findElement(
              shelf,
              (element) =>
                  element.widget.key ==
                      const ValueKey('contentShelfNextButton') &&
                  element.widget is IconButton,
            );
      callback = (button?.widget as IconButton?)?.onPressed;
    }
    // A local copy: the row search assigns [callback] from a closure.
    final resolved = callback;
    if (resolved == null) throw const DiagnosticsPresentationUnavailable();
    resolved();
    await waitForFrame();
  }

  /// Flips a mounted Playback settings switch through its own callback, so
  /// the screen's debounced autosave persists the change.
  Future<void> togglePlaybackSetting({required String setting}) async {
    final key = playbackSettingToggles[setting];
    if (key == null) throw const FormatException();
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final tile =
        _findElement(
              root,
              (element) =>
                  element.widget.key == ValueKey<String>(key) &&
                  element.widget is SwitchListTile,
            )?.widget
            as SwitchListTile?;
    final onChanged = tile?.onChanged;
    if (tile == null || onChanged == null) {
      throw const DiagnosticsPresentationUnavailable();
    }
    onChanged(!tile.value);
    await waitForFrame();
  }

  /// Drives bounded tooltip hover through Flutter's own input and semantics.
  Future<bool> hoverTooltip({required String? target}) async {
    if (target != null && !tooltipTargets.containsKey(target)) {
      throw const FormatException('unsupported tooltip target');
    }
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final viewId = View.of(root).viewId;
    final binding = WidgetsBinding.instance;
    if (target == null) {
      if (_tooltipPointerAdded) {
        binding.handlePointerEvent(
          PointerRemovedEvent(
            viewId: viewId,
            kind: PointerDeviceKind.mouse,
            device: _tooltipPointerDevice,
          ),
        );
        _tooltipPointerAdded = false;
      }
    } else {
      final element = _findElement(
        root,
        (element) =>
            element.widget.key == ValueKey<String>(tooltipTargets[target]!),
      );
      final box = element?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) {
        throw const DiagnosticsPresentationUnavailable();
      }
      _tooltipSemantics ??= binding.ensureSemantics();
      final position = box.localToGlobal(box.size.center(Offset.zero));
      if (!_tooltipPointerAdded) {
        binding.handlePointerEvent(
          PointerAddedEvent(
            viewId: viewId,
            kind: PointerDeviceKind.mouse,
            device: _tooltipPointerDevice,
            position: position,
          ),
        );
        _tooltipPointerAdded = true;
      }
      binding.handlePointerEvent(
        PointerHoverEvent(
          viewId: viewId,
          kind: PointerDeviceKind.mouse,
          device: _tooltipPointerDevice,
          position: position,
        ),
      );
    }
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    var visible = false;
    do {
      await waitForFrame();
      visible = _tooltipVisible;
      if (visible == (target != null)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } while (DateTime.now().isBefore(deadline));
    if (target == null) {
      _tooltipSemantics?.dispose();
      _tooltipSemantics = null;
    }
    return visible;
  }

  bool get _tooltipVisible {
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    return _findElement(
          root,
          (element) => element.widget.key == NavisTooltip.defaultBubbleKey,
        ) !=
        null;
  }

  /// Sends the platform back request, as Android's back button or gesture
  /// does, through the app's root back-button dispatcher.
  Future<void> systemBack() async {
    // The same message the Android embedding sends on back.
    final message = SystemChannels.navigation.codec.encodeMethodCall(
      const MethodCall('popRoute'),
    );
    final delivered = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      SystemChannels.navigation.name,
      message,
      (_) => delivered.complete(),
    );
    await delivered.future;
    await waitForFrame();
  }

  /// Taps the visible shell destination at [index] with a real pointer, on
  /// whichever navigation the current layout shows (bottom bar, rail or
  /// compact rail).
  Future<void> tapNavigationDestination(int index) async {
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    var target = _findElement(
      root,
      (element) =>
          element.widget.key == ValueKey<String>('railNavTile-$index') ||
          element.widget.key == ValueKey<String>('compactRailNavTile-$index'),
    );
    if (target == null) {
      final bar = _findElement(
        root,
        (element) => element.widget is NavigationBar,
      );
      final destinations = <Element>[];
      void collect(Element element) {
        if (element.widget is NavigationDestination) {
          destinations.add(element);
          return;
        }
        element.visitChildElements(collect);
      }

      bar?.visitChildElements(collect);
      if (index < destinations.length) {
        target = destinations[index];
      }
    }
    final box = target?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      throw const DiagnosticsPresentationUnavailable();
    }
    final position = box.localToGlobal(box.size.center(Offset.zero));
    final binding = GestureBinding.instance;
    final viewId = View.of(root).viewId;
    const pointer = 9282;
    binding.handlePointerEvent(
      PointerDownEvent(pointer: pointer, position: position, viewId: viewId),
    );
    binding.handlePointerEvent(
      PointerUpEvent(pointer: pointer, position: position, viewId: viewId),
    );
    await waitForFrame();
  }

  /// Fields of the onboarding Integrations step the diagnostics API may focus,
  /// by the widget key of their text field.
  static const onboardingFocusFields = <String, String>{
    'listenBrainzToken': 'onboarding-listenbrainz-token',
    'lastFmKey': 'onboarding-lastfm-key',
  };

  /// Card lists the diagnostics API may tap, by the widget-key prefix of
  /// their cards: the artist page's missing albums and Home's New releases.
  static const releaseSurfaces = <String, String>{
    'missingAlbums': 'missing-album-',
    'newReleases': 'home-new-release-',
  };

  OnboardingScreenState _onboardingState() {
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final element = _findElement(
      root,
      (element) =>
          element is StatefulElement &&
          element.state is OnboardingScreenState &&
          _isOnstage(element),
    );
    if (element is! StatefulElement) {
      throw const DiagnosticsPresentationUnavailable();
    }
    return element.state as OnboardingScreenState;
  }

  /// Moves the mounted onboarding screen to [step] (0-based) through the
  /// screen's own step state, as Next and Back do, and returns the step shown.
  Future<int> setOnboardingStep(int step) async {
    final screen = _onboardingState();
    if (step < 0 || step >= OnboardingScreenState.stepCount) {
      throw const DiagnosticsPresentationOutOfRange(
        OnboardingScreenState.stepCount,
      );
    }
    screen.showStep(step);
    await waitForFrame();
    if (!screen.mounted) throw const DiagnosticsPresentationUnavailable();
    return screen.step;
  }

  /// Gives a mounted onboarding text field (a key of [onboardingFocusFields])
  /// focus through its production focus node, which opens the platform
  /// keyboard, or takes focus away for `none`. Returns whether the field now
  /// has focus; a field that is not shown or cannot take focus is unavailable.
  Future<bool> focusOnboardingField(String field) async {
    if (field != 'none' && !onboardingFocusFields.containsKey(field)) {
      throw const FormatException();
    }
    final screen = _onboardingState();
    if (field == 'none') {
      FocusManager.instance.primaryFocus?.unfocus();
      await waitForFrame();
      return false;
    }
    if (screen.step != OnboardingScreenState.integrationsStep) {
      throw const DiagnosticsPresentationUnavailable();
    }
    final root = _boundaryElement();
    Element? findInput() => _findElement(
      root,
      (element) =>
          element.widget.key ==
              ValueKey<String>(onboardingFocusFields[field]!) &&
          element.widget is TextField &&
          _isOnstage(element),
    );
    var input = findInput();
    if (input == null) {
      // The step list builds lazily, so a field below the fold on a short
      // screen is not built yet: scroll to the end of the step to build it.
      try {
        await scrollPrimary(to: 100000);
      } on DiagnosticsPresentationUnavailable {
        // No scrollable step: the field is simply not shown.
      }
      input = findInput();
    }
    final node = (input?.widget as TextField?)?.focusNode;
    if (node == null) throw const DiagnosticsPresentationUnavailable();
    node.requestFocus();
    await waitForFrame();
    if (!screen.mounted || !node.hasFocus) {
      throw const DiagnosticsPresentationUnavailable();
    }
    return true;
  }

  /// Taps the release card at [index] of [surface] (a key of
  /// [releaseSurfaces]) through the card's own callback, which opens an album
  /// page: the library album, or the server's remote `ext-deezer-album-*`.
  /// Reports how that page ended up: `albumPage` once it marks the album as
  /// shown, `failed` when the server could not provide it (the page offers
  /// Retry and a search), `loading` when it still loads after [timeout],
  /// `unknown` when it shows neither by then, `otherPage` when the location
  /// is not an album page, or `none` when the tap did not navigate within
  /// [navigationTimeout].
  Future<DiagnosticsReleaseCardResult> tapReleaseCard({
    required String surface,
    required int index,
    required String? Function() location,
    Duration navigationTimeout = const Duration(seconds: 8),
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final prefix = releaseSurfaces[surface];
    if (prefix == null || index < 0) throw const FormatException();
    final root = _boundaryElement();
    final cards = <ExternalAlbumCard>[];
    void collect(Element element) {
      final widget = element.widget;
      final key = widget.key;
      if (widget is ExternalAlbumCard &&
          key is ValueKey<String> &&
          key.value.startsWith(prefix) &&
          _isOnstage(element) &&
          ModalRoute.of(element)?.isCurrent != false) {
        cards.add(widget);
        return;
      }
      element.visitChildElements(collect);
    }

    collect(root);
    if (cards.isEmpty) throw const DiagnosticsPresentationUnavailable();
    if (index >= cards.length) {
      throw DiagnosticsPresentationOutOfRange(cards.length);
    }
    final onTap = cards[index].onTap;
    if (onTap == null) throw const DiagnosticsPresentationUnavailable();
    final before = location();
    onTap();
    final navigationDeadline = DateTime.now().add(navigationTimeout);
    while (location() == before) {
      if (!DateTime.now().isBefore(navigationDeadline)) {
        return DiagnosticsReleaseCardResult(outcome: 'none', location: before);
      }
      await waitForFrame();
    }
    final deadline = DateTime.now().add(timeout);
    while (true) {
      await waitForFrame();
      final after = location();
      final path = after == null ? null : Uri.tryParse(after)?.path;
      if (path == null || !path.startsWith(AppRoutes.album(''))) {
        return DiagnosticsReleaseCardResult(
          outcome: 'otherPage',
          location: after,
        );
      }
      if (_currentPageShows(DetailLoadFailedView.failedKey)) {
        return DiagnosticsReleaseCardResult(outcome: 'failed', location: after);
      }
      if (_currentPageShows(detailPageShownKey)) {
        return DiagnosticsReleaseCardResult(
          outcome: 'albumPage',
          location: after,
        );
      }
      if (!DateTime.now().isBefore(deadline)) {
        return DiagnosticsReleaseCardResult(
          outcome: _currentPageShows(DetailLoadingView.loadingKey)
              ? 'loading'
              : 'unknown',
          location: after,
        );
      }
    }
  }

  /// Whether the current page shows a widget keyed [key].
  bool _currentPageShows(Key key) {
    final root = _boundaryKey.currentContext;
    if (root is! Element) return false;
    return _findElement(
          root,
          (element) =>
              element.widget.key == key &&
              _isOnstage(element) &&
              ModalRoute.of(element)?.isCurrent != false,
        ) !=
        null;
  }

  Element? _findElement(Element root, bool Function(Element) matches) {
    if (matches(root)) return root;
    Element? result;
    root.visitChildElements((child) {
      result ??= _findElement(child, matches);
    });
    return result;
  }

  /// Scrolls the current page's primary vertical scroll view [by] pixels or
  /// [to] an offset (exactly one), clamped to its extent, through the
  /// production widget tree.
  ///
  /// The primary view is the largest vertical scrollable on screen: outside
  /// any offstage or ticker-disabled subtree (hidden shell tabs, the hidden
  /// desktop workspace) and on the current page of its navigator. Nested
  /// lists, such as a hero's track list, are smaller than the page's own.
  /// Returns the position after the next quiet frame, once lazily built
  /// content has updated the extent.
  Future<DiagnosticsScrollResult> scrollPrimary({
    double? by,
    double? to,
  }) async {
    if ((by == null) == (to == null)) throw const FormatException();
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    ScrollableState? primary;
    var primaryArea = 0.0;
    void collect(Element element) {
      final widget = element.widget;
      if ((widget is Offstage && widget.offstage) ||
          (widget is TickerMode && !widget.enabled)) {
        return;
      }
      if (element is StatefulElement &&
          element.state is ScrollableState &&
          ModalRoute.of(element)?.isCurrent != false) {
        final state = element.state as ScrollableState;
        final box = element.findRenderObject();
        if (axisDirectionToAxis(state.axisDirection) == Axis.vertical &&
            box is RenderBox &&
            box.attached &&
            box.hasSize &&
            state.position.hasContentDimensions) {
          final area = box.size.width * box.size.height;
          if (area > primaryArea) {
            primary = state;
            primaryArea = area;
          }
        }
      }
      element.visitChildElements(collect);
    }

    collect(root);
    final position = primary?.position;
    if (position == null) throw const DiagnosticsPresentationUnavailable();
    final target = (to ?? position.pixels + by!).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.jumpTo(target);
    await waitForFrame();
    return DiagnosticsScrollResult(
      pixels: position.pixels,
      maxScrollExtent: position.maxScrollExtent,
      viewportDimension: position.viewportDimension,
    );
  }

  /// Dismisses app-owned popup routes without navigating away from a page.
  Future<void> dismissPopupRoutes() async {
    final root = _boundaryKey.currentContext;
    if (root is! Element) throw const DiagnosticsPresentationUnavailable();
    final element = _findElement(
      root,
      (element) => element.widget is Navigator,
    );
    if (element is! StatefulElement || element.state is! NavigatorState) {
      throw const DiagnosticsPresentationUnavailable();
    }
    (element.state as NavigatorState).popUntil((route) => route is! PopupRoute);
    await waitForFrame();
  }

  Widget wrap(Widget child) {
    return RepaintBoundary(key: _boundaryKey, child: child);
  }

  DiagnosticsPresentationStatus get status {
    final context = _boundaryKey.currentContext;
    final boundary = _boundary;
    final size = (boundary?.hasSize ?? false) ? boundary!.size : Size.zero;
    final pixelRatio = context == null
        ? 0.0
        : View.of(context).devicePixelRatio;
    return DiagnosticsPresentationStatus(
      logicalWidth: size.width,
      logicalHeight: size.height,
      devicePixelRatio: pixelRatio,
      screenshotReady:
          boundary != null && boundary.attached && boundary.hasSize,
    );
  }

  Future<void> waitForFrame() async {
    final waitOverride = frameWaiter;
    if (waitOverride != null) {
      await waitOverride();
      return;
    }
    final binding = WidgetsBinding.instance;
    var consecutiveQuietFrames = 0;
    for (var frame = 0; frame < 120; frame++) {
      binding.ensureVisualUpdate();
      await binding.endOfFrame;
      if (binding.transientCallbackCount == 0) {
        consecutiveQuietFrames++;
        if (consecutiveQuietFrames >= 2) {
          return;
        }
      } else {
        consecutiveQuietFrames = 0;
      }
    }
  }

  Future<DiagnosticsScreenshot> capture({required String label}) async {
    if (!isValidLabel(label)) {
      throw const FormatException('label must match [a-z0-9][a-z0-9_-]{0,47}');
    }

    await waitForFrame();
    final boundary = _boundary;
    if (boundary == null || !boundary.attached || !boundary.hasSize) {
      throw const DiagnosticsPresentationUnavailable();
    }

    final image = await boundary.toImage(pixelRatio: _capturePixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw const DiagnosticsPresentationUnavailable();
      }
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final screenshots = Directory(p.join(_artifactRoot.path, 'screenshots'));
      await screenshots.create(recursive: true);
      _setPosixMode(screenshots.path, '700');

      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp('[^0-9]'),
        '',
      );
      final file = File(p.join(screenshots.path, '$timestamp-$label.png'));
      final normalizedFile = p.normalize(p.absolute(file.path));
      if (!p.isWithin(_artifactRoot.path, normalizedFile)) {
        throw StateError('Screenshot path escaped the diagnostics root.');
      }
      await file.writeAsBytes(bytes, flush: true);
      _setPosixMode(file.path, '600');

      return DiagnosticsScreenshot(
        artifact: p.relative(file.path, from: _artifactRoot.path),
        logicalWidth: boundary.size.width,
        logicalHeight: boundary.size.height,
        pixelWidth: image.width,
        pixelHeight: image.height,
        pixelRatio: _capturePixelRatio,
        byteCount: bytes.length,
        sha256Digest: sha256.convert(bytes).toString(),
      );
    } finally {
      image.dispose();
    }
  }

  RenderRepaintBoundary? get _boundary {
    final renderObject = _boundaryKey.currentContext?.findRenderObject();
    return renderObject is RenderRepaintBoundary ? renderObject : null;
  }

  void _setPosixMode(String path, String mode) {
    // Android primary certification writes below the sidecar's scoped
    // external-files directory. POSIX chmod is unavailable there; Android's
    // scoped-storage boundary provides the relevant protection instead.
    if (Platform.isWindows || Platform.isAndroid) return;
    final result = Process.runSync('chmod', <String>[mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not protect diagnostics artifact.',
        path,
      );
    }
  }
}
