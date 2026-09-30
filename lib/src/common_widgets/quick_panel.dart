import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/desktop/desktop_anchored_popover.dart';
import 'package:navis/src/routing/desktop_layout.dart';

/// Opens a compact control panel from a player button.
///
/// Desktop anchors a popover to the widget that owns [anchorContext]; touch
/// layouts use a content-sized bottom sheet capped at 88% of the screen. Both
/// share [QuickPanelScaffold]: a pinned header, a scrolling body and an
/// optional pinned footer, so titles and primary actions never scroll away.
Future<void> showQuickPanel(
  BuildContext anchorContext, {
  required String title,
  required WidgetBuilder bodyBuilder,
  WidgetBuilder? subtitleBuilder,
  WidgetBuilder? headerTrailingBuilder,
  WidgetBuilder? footerBuilder,
  double width = 420,
  double maxHeight = 640,
  Key? panelKey,
}) {
  Widget panel(BuildContext context, {required bool sheet}) =>
      QuickPanelScaffold(
        key: panelKey,
        title: title,
        subtitle: subtitleBuilder?.call(context),
        headerTrailing: headerTrailingBuilder?.call(context),
        footer: footerBuilder?.call(context),
        sheet: sheet,
        onClose: () => Navigator.of(context).pop(),
        body: bodyBuilder(context),
      );

  if (resolveAdaptiveContextFor(anchorContext).desktopRuntime) {
    return showDesktopAnchoredPopover<void>(
      anchorContext: anchorContext,
      width: width,
      maxHeight: maxHeight,
      builder: (context) => panel(context, sheet: false),
    );
  }
  final screenHeight = MediaQuery.sizeOf(anchorContext).height;
  return showModalBottomSheet<void>(
    context: anchorContext,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: screenHeight * 0.88),
    builder: (context) => panel(context, sheet: true),
  );
}

/// Pinned header, scrolling body and pinned footer for quick panels.
class QuickPanelScaffold extends StatefulWidget {
  const QuickPanelScaffold({
    required this.title,
    required this.body,
    required this.onClose,
    this.subtitle,
    this.headerTrailing,
    this.footer,
    this.sheet = false,
    super.key,
  });

  final String title;
  final Widget? subtitle;
  final Widget? headerTrailing;
  final Widget body;
  final Widget? footer;
  final VoidCallback onClose;

  /// Sheets already show a drag handle above the header, so the header
  /// sits closer to the top edge.
  final bool sheet;

  @override
  State<QuickPanelScaffold> createState() => _QuickPanelScaffoldState();
}

class _QuickPanelScaffoldState extends State<QuickPanelScaffold> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // Sheets extend behind Android's navigation bar (the modal route only
    // guards the top), so the last pinned row adds the live bottom inset:
    // taller for 3-button navigation, thin for gestures, and the keyboard
    // when it is open. Popovers sit inside the window and need none.
    final systemInset = widget.sheet
        ? MediaQuery.paddingOf(context).bottom +
              MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    final divider = Divider(
      height: 1,
      thickness: 1,
      color: colors.outlineVariant.withValues(alpha: 0.5),
    );
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: widget.title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, widget.sheet ? 0 : 12, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        key: const ValueKey<String>('quickPanelTitle'),
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.subtitle != null)
                        DefaultTextStyle.merge(
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          child: widget.subtitle!,
                        ),
                    ],
                  ),
                ),
                if (widget.headerTrailing != null) ...[
                  const SizedBox(width: 8),
                  widget.headerTrailing!,
                ],
                IconButton(
                  key: const ValueKey<String>('quickPanelClose'),
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).closeButtonTooltip,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          divider,
          Flexible(
            child: ScrollEdgeFade(
              controller: _scroll,
              child: Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  key: const ValueKey<String>('quickPanelBody'),
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    16 + (widget.footer == null ? systemInset : 0),
                  ),
                  child: widget.body,
                ),
              ),
            ),
          ),
          if (widget.footer != null) ...[
            divider,
            Padding(
              key: const ValueKey<String>('quickPanelFooter'),
              padding: EdgeInsets.fromLTRB(12, 8, 12, 10 + systemInset),
              child: widget.footer,
            ),
          ],
        ],
      ),
    );
  }
}

/// Fades the leading and trailing edges of a scroll view only while more
/// content lies beyond that edge, hinting that the area scrolls.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({
    required this.controller,
    required this.child,
    this.axis = Axis.vertical,
    this.extent = 20,
    super.key,
  });

  final ScrollController controller;
  final Widget child;
  final Axis axis;
  final double extent;

  @override
  State<ScrollEdgeFade> createState() => ScrollEdgeFadeState();
}

class ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  bool _leading = false;
  bool _trailing = false;

  /// Whether content lies beyond the leading (top/left) edge.
  @visibleForTesting
  bool get fadesLeading => _leading;

  /// Whether content lies beyond the trailing (bottom/right) edge.
  @visibleForTesting
  bool get fadesTrailing => _trailing;

  void _update(ScrollMetrics metrics) {
    if (metrics.axis != widget.axis) return;
    final leading = metrics.extentBefore > 0.5;
    final trailing = metrics.extentAfter > 0.5;
    if (leading != _leading || trailing != _trailing) {
      setState(() {
        _leading = leading;
        _trailing = trailing;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        _update(notification.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _update(notification.metrics);
          return false;
        },
        child: widget.child,
      ),
    );
    // The mask stays mounted even when fully opaque so toggling a fade never
    // rebuilds the scroll view underneath (and loses its position).
    return ShaderMask(
      key: const ValueKey<String>('scrollEdgeFade'),
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final length = widget.axis == Axis.vertical
            ? bounds.height
            : bounds.width;
        final stop = length <= 0
            ? 0.0
            : (widget.extent / length).clamp(0.0, 0.5);
        return LinearGradient(
          begin: widget.axis == Axis.vertical
              ? Alignment.topCenter
              : Alignment.centerLeft,
          end: widget.axis == Axis.vertical
              ? Alignment.bottomCenter
              : Alignment.centerRight,
          colors: [
            if (_leading) Colors.transparent else Colors.black,
            Colors.black,
            Colors.black,
            if (_trailing) Colors.transparent else Colors.black,
          ],
          stops: [0, stop, 1 - stop, 1],
        ).createShader(bounds);
      },
      child: content,
    );
  }
}
