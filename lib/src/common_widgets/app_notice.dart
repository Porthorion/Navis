import 'dart:async';

import 'package:flutter/material.dart';

enum AppNoticeLevel { info, success, error }

@immutable
class AppNoticeData {
  const AppNoticeData({
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
    _dismissTimer = Timer(duration, dismiss);
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
  const AppNoticeScope({
    required super.notifier,
    required super.child,
    super.key,
  });

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
  const AppNoticeMessenger._(this.context);

  factory AppNoticeMessenger.of(BuildContext context) {
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
    controller.show(
      message: message,
      duration: snackBar.duration,
    );
  }

  String? _extractMessage(Widget content) {
    if (content case final Text text) {
      return text.data ?? text.textSpan?.toPlainText();
    }
    return null;
  }
}

class AppNoticeHost extends StatelessWidget {
  const AppNoticeHost({
    required this.controller,
    this.topOffset = 12,
    super.key,
  });

  final AppNoticeController controller;
  final double topOffset;

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.paddingOf(context);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(
          top: mediaPadding.top + topOffset,
          left: 12,
          right: 12,
        ),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final slide = Tween<Offset>(
                  begin: const Offset(0, -0.18),
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
  const _NoticePill({
    required this.notice,
    required this.onDismissed,
    super.key,
  });

  final AppNoticeData notice;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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
      button: true,
      label: notice.message,
      onTap: onDismissed,
      child: ExcludeSemantics(
        child: Dismissible(
          key: ValueKey<int>(notice.id),
          direction: DismissDirection.up,
          onDismissed: (_) => onDismissed(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(999),
              color: bgColor,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: onDismissed,
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
                        child: Text(
                          notice.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: fgColor),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
