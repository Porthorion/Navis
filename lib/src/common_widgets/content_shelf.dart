import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/mouse_drag_scroll.dart';
import 'package:navis/src/routing/desktop_layout.dart';

/// A bounded, lazy horizontal preview that retains its position on resize.
class ContentShelf extends StatefulWidget {
  const ContentShelf({
    required this.itemCount,
    required this.extent,
    required this.height,
    required this.gap,
    required this.itemBuilder,
    this.showNextTooltip = true,
    super.key,
  });

  final int itemCount;
  final double extent;
  final double height;
  final double gap;
  final IndexedWidgetBuilder itemBuilder;
  final bool showNextTooltip;

  @override
  State<ContentShelf> createState() => _ContentShelfState();
}

class _ContentShelfState extends State<ContentShelf> {
  final _controller = ScrollController();
  bool _canBack = false;
  bool _canForward = false;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_scheduleMetrics);
  }

  void _scheduleMetrics() {
    if (_scheduled) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          !_controller.hasClients ||
          !_controller.position.hasContentDimensions) {
        return;
      }
      final position = _controller.position;
      final back = position.extentBefore > 1;
      final forward = position.extentAfter > 1;
      if (back != _canBack || forward != _canForward) {
        setState(() {
          _canBack = back;
          _canForward = forward;
        });
      }
    });
  }

  void _page(int direction) {
    if (!_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    final target =
        (position.pixels + direction * position.viewportDimension * .85).clamp(
          0.0,
          position.maxScrollExtent,
        );
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpTo(target);
    } else {
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMetrics();
    final desktop = resolveAdaptiveContextFor(context).desktopRuntime;
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: widget.height,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _scheduleMetrics();
          return false;
        },
        child: Stack(
          children: [
            MouseDragScroll(
              child: ListView.separated(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                itemCount: widget.itemCount,
                separatorBuilder: (_, _) => SizedBox(width: widget.gap),
                itemBuilder: (context, index) => SizedBox(
                  width: widget.extent,
                  child: widget.itemBuilder(context, index),
                ),
              ),
            ),
            if (desktop && _canBack)
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton.filledTonal(
                  tooltip: l10n.contentShelfPrevious,
                  onPressed: () => _page(-1),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.chevron_left),
                ),
              ),
            if (desktop && _canForward)
              Align(
                alignment: Alignment.centerRight,
                child: MergeSemantics(
                  child: Semantics(
                    label: widget.showNextTooltip
                        ? null
                        : l10n.contentShelfNext,
                    child: IconButton.filledTonal(
                      key: const ValueKey('contentShelfNextButton'),
                      tooltip: widget.showNextTooltip
                          ? l10n.contentShelfNext
                          : null,
                      onPressed: () => _page(1),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
