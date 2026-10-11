import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/notice_icon_disc.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';
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
    this.actionLabel,
    this.onAction,
  });

  final int id;
  final String message;
  final AppNoticeLevel level;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
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
    String? actionLabel,
    VoidCallback? onAction,
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
      actionLabel: actionLabel,
      onAction: onAction,
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
  String? actionLabel,
  VoidCallback? onAction,
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
    actionLabel: actionLabel,
    onAction: onAction,
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isError = notice.level == AppNoticeLevel.error;
    final shapes = NavisShapeData.of(context);
    final style = NavisColorStyleData.of(context);
    final success = NavisTokens.of(context).success;
    final surface = theme.brightness == Brightness.dark
        ? colorScheme.surfaceContainerHighest
        : colorScheme.surfaceContainerHigh;
    // A neutral pill for every kind; only the leading disc carries the kind.
    final (icon, discFill, discInk) = switch (notice.level) {
      AppNoticeLevel.success => (
        Icons.check_rounded,
        Color.alphaBlend(success.withValues(alpha: .2), surface),
        success,
      ),
      AppNoticeLevel.error => (
        Icons.error_outline,
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
      AppNoticeLevel.info => (
        Icons.info_outline,
        style.tonalControlFill(colorScheme),
        style.onTonalControlFill(colorScheme),
      ),
    };
    final shape = RoundedRectangleBorder(borderRadius: shapes.controlAll);

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
            elevation: 3,
            shape: shape,
            color: surface,
            child: InkWell(
              customBorder: shape,
              onTap: isError ? null : onDismissed,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  NavisSpace.xs,
                  NavisSpace.xs,
                  NavisSpace.md,
                  NavisSpace.xs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    NoticeIconDisc(
                      icon: icon,
                      size: 30,
                      iconSize: 18,
                      fill: discFill,
                      ink: discInk,
                    ),
                    const SizedBox(width: NavisSpace.sm),
                    Flexible(
                      child: ExcludeSemantics(
                        child: Text(
                          notice.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                    if (notice.actionLabel != null && notice.onAction != null)
                      TextButton(
                        onPressed: () {
                          onDismissed();
                          notice.onAction!();
                        },
                        child: Text(notice.actionLabel!),
                      ),
                    if (isError) ...<Widget>[
                      const SizedBox(width: NavisSpace.xxs),
                      TextButton(
                        key: const ValueKey<String>('appNoticeDismissAction'),
                        onPressed: onDismissed,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: NavisSpace.sm,
                          ),
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
