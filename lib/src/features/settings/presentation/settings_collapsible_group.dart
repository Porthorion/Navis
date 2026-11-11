import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/settings/presentation/appearance_options.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/motion_policy.dart';

class SettingsCollapsibleGroup extends StatefulWidget {
  const new({
    required this.leading,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
    this.adornment,
    this.outerPadding = const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    this.buildCollapsed = true,
    super.key,
  });

  final Widget leading;
  final String title;
  final Widget child;
  final bool initiallyExpanded;

  /// Shown beside the title, for example a "New" tag for an option inside the
  /// collapsed group.
  final Widget? adornment;

  /// Space around the card.
  final EdgeInsetsGeometry outerPadding;

  /// Whether [child] stays built (but hidden) while collapsed. Setup turns
  /// this off so hidden options are neither focusable nor counted as shown.
  final bool buildCollapsed;

  @override
  State<SettingsCollapsibleGroup> createState() =>
      SettingsCollapsibleGroupState();
}

class SettingsCollapsibleGroupState extends State<SettingsCollapsibleGroup> {
  Duration get _duration => MotionPolicy.of(context).surface;
  bool _expanded = false;
  bool _childBuilt = true;
  bool _userToggled = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    _childBuilt = widget.buildCollapsed || _expanded;
  }

  @override
  void didUpdateWidget(SettingsCollapsibleGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A group that was told late to start open (its trigger loads
    // asynchronously) still opens, unless the user already chose.
    if (!_userToggled && widget.initiallyExpanded && !_expanded) {
      _expanded = true;
      _childBuilt = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: widget.outerPadding,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: NavisShapeData.of(context).mdAll,
        child: Column(
          children: <Widget>[
            InkWell(
              borderRadius: NavisShapeData.of(context).mdAll,
              onTap: () {
                final nextExpanded = !_expanded;
                setState(() {
                  _userToggled = true;
                  _expanded = nextExpanded;
                  if (nextExpanded) _childBuilt = true;
                });
                if (!nextExpanded) {
                  return;
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) {
                    return;
                  }
                  Scrollable.ensureVisible(
                    context,
                    alignment: 0.02,
                    duration: MotionPolicy.of(context).surface,
                    curve: Curves.easeOutCubic,
                  );
                });
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                child: Row(
                  children: <Widget>[
                    IconTheme.merge(
                      data: IconThemeData(
                        color: theme.colorScheme.primary,
                        size: 22,
                      ),
                      child: widget.leading,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          titleWithAdornment(
                            widget.title,
                            widget.adornment,
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: _duration,
                      curve: Curves.easeOutCubic,
                      child: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ],
                ),
              ),
            ),
            ClipRect(
              child: AnimatedAlign(
                alignment: Alignment.topCenter,
                heightFactor: _expanded ? 1 : 0,
                duration: _duration,
                curve: Curves.easeOutCubic,
                onEnd: () {
                  if (!_expanded && !widget.buildCollapsed && _childBuilt) {
                    setState(() => _childBuilt = false);
                  }
                },
                child: AnimatedOpacity(
                  opacity: _expanded ? 1 : 0,
                  duration: MotionPolicy.of(context).surface,
                  curve: Curves.easeOutCubic,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _childBuilt ? widget.child : const SizedBox.shrink(),
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
