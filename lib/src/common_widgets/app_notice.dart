import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/motion_policy.dart';

enum AppNoticeLevel { info, success, error }

/// Clone-diagnostics command for exercising the mounted global notice host.
/// Ordinary product flows call [showAppNotice] directly and never write this
/// provider.
@immutable
class AppNoticeDiagnosticsCommand {
  const new({required this.message, required this.level});

  final String message;
  final AppNoticeLevel level;
}

class AppNoticeDiagnosticsController
    extends Notifier<AppNoticeDiagnosticsCommand?> {
  @override
  AppNoticeDiagnosticsCommand? build() => null;

  void show({required String message, required AppNoticeLevel level}) {
    state = AppNoticeDiagnosticsCommand(message: message, level: level);
  }
}

final appNoticeDiagnosticsProvider =
    NotifierProvider<
      AppNoticeDiagnosticsController,
      AppNoticeDiagnosticsCommand?
    >(AppNoticeDiagnosticsController.new);

@immutable
class AppNoticeData {
  const new({
    required this.id,
    required this.message,
    required this.level,
    required this.duration,
  });

  final int id;
  final String message;
  final AppNoticeLevel level;
  final Duration duration;
}

class AppNoticeController extends ChangeNotifier {
  AppNoticeData? get notice => _notice;
  AppNoticeData? _notice;

  Timer? _dismissTimer;
  int _nextId = 0;

  void show({
    required String message,
    AppNoticeLevel level = AppNoticeLevel.info,
    Duration duration = const Duration(seconds: 2),
    bool replaceCurrent = true,
  }) {
    if (message.trim().isEmpty) {
      return;
    }
    final activeNotice = _notice;
    // A failure remains the current task until the person dismisses it or a
    // newer failure supersedes it. Routine confirmations must not erase a
    // recovery message before it can be read.
    if (activeNotice?.level == AppNoticeLevel.error &&
        level != AppNoticeLevel.error) {
      return;
    }
    if (!replaceCurrent && _notice != null) {
      return;
    }
    _dismissTimer?.cancel();
    _notice = AppNoticeData(
      id: ++_nextId,
      message: message,
      level: level,
      duration: duration,
    );
    notifyListeners();
    if (level != AppNoticeLevel.error) {
      _dismissTimer = Timer(duration, dismiss);
    }
  }

  void dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    if (_notice == null) {
      return;
    }
    _notice = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }
}

class AppNoticeScope extends InheritedNotifier<AppNoticeController> {
  const new({required super.notifier, required super.child, super.key});

  static AppNoticeController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AppNoticeScope>()
        ?.notifier;
  }
}

void showAppNotice(
  BuildContext context, {
  required String message,
  AppNoticeLevel level = AppNoticeLevel.info,
  Duration duration = const Duration(seconds: 2),
  bool replaceCurrent = true,
}) {
  final controller = AppNoticeScope.maybeOf(context);
  if (controller == null) {
    return;
  }
  controller.show(
    message: message,
    level: level,
    duration: duration,
    replaceCurrent: replaceCurrent,
  );
}

class AppNoticeMessenger {
  const new _(this.context);

  factory of(BuildContext context) {
    return AppNoticeMessenger._(context);
  }

  final BuildContext context;

  void clearSnackBars() {
    final controller = AppNoticeScope.maybeOf(context);
    if (controller == null) {
      return;
    }
    controller.dismiss();
  }

  void showSnackBar(SnackBar snackBar) {
    final controller = AppNoticeScope.maybeOf(context);
    final message = _extractMessage(snackBar.content);
    if (controller == null || message == null || message.trim().isEmpty) {
      return;
    }
    controller.show(message: message, duration: snackBar.duration);
  }

  String? _extractMessage(Widget content) {
    if (content case final Text text) {
      return text.data ?? text.textSpan?.toPlainText();
    }
    return null;
  }
}

class AppNoticeHost extends StatelessWidget {
  const new({
    required this.controller,
    this.topOffset = 12,
    this.bottomOffset,
    super.key,
  });

  final AppNoticeController controller;
  final double topOffset;

  /// When set, notices sit this far above the bottom edge instead of at the
  /// top. The desktop shell uses it so a notice rests above the player bar
  /// rather than over page titles and toolbars.
  final double? bottomOffset;

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.paddingOf(context);
    final bottom = bottomOffset;
    return Align(
      alignment: bottom == null ? Alignment.topCenter : Alignment.bottomCenter,
      child: Padding(
        padding: bottom == null
            ? EdgeInsets.only(
                top: mediaPadding.top + topOffset,
                left: 12,
                right: 12,
              )
            : EdgeInsets.only(
                bottom: mediaPadding.bottom + bottom,
                left: 12,
                right: 12,
              ),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final motion = MotionPolicy.of(context);
            return AnimatedSwitcher(
              duration: motion.surface,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final slide = Tween<Offset>(
                  begin: Offset(0, bottom == null ? -0.18 : 0.18),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(position: slide, child: child),
                );
              },
              child: controller.notice == null
                  ? const SizedBox.shrink()
                  : _NoticePill(
                      key: ValueKey<int>(controller.notice!.id),
                      notice: controller.notice!,
                      onDismissed: controller.dismiss,
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _NoticePill extends StatelessWidget {
  const new({required this.notice, required this.onDismissed, super.key});

  final AppNoticeData notice;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isError = notice.level == AppNoticeLevel.error;
    final shapes = NavisShapeData.of(context);
    final (icon, bgColor, fgColor) = switch (notice.level) {
      AppNoticeLevel.success => (
        Icons.check_circle_outline,
        colorScheme.primaryContainer,
        colorScheme.onPrimaryContainer,
      ),
      AppNoticeLevel.error => (
        Icons.error_outline,
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
      AppNoticeLevel.info => (
        Icons.info_outline,
        colorScheme.surfaceContainerHigh,
        colorScheme.onSurface,
      ),
    };

    return Semantics(
      container: true,
      liveRegion: true,
      button: !isError,
      label: notice.message,
      onTap: isError ? null : onDismissed,
      child: Dismissible(
        key: ValueKey<int>(notice.id),
        direction: DismissDirection.up,
        onDismissed: (_) => onDismissed(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Material(
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: (isError
                  ? shapes.scaledAll(22)
                  : shapes.controlAll),
              side: isError
                  ? BorderSide(color: colorScheme.error.withValues(alpha: .55))
                  : BorderSide.none,
            ),
            color: bgColor,
            child: InkWell(
              borderRadius: (isError
                  ? shapes.scaledAll(22)
                  : shapes.controlAll),
              onTap: isError ? null : onDismissed,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(icon, size: 18, color: fgColor),
                    const SizedBox(width: 10),
                    Flexible(
                      child: ExcludeSemantics(
                        child: Text(
                          notice.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: fgColor),
                        ),
                      ),
                    ),
                    if (isError) ...<Widget>[
                      const SizedBox(width: 6),
                      TextButton(
                        key: const ValueKey<String>('appNoticeDismissAction'),
                        onPressed: onDismissed,
                        style: TextButton.styleFrom(
                          foregroundColor: fgColor,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 36),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(
                          AppLocalizations.of(context)?.updateDismiss ??
                              'Dismiss',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
