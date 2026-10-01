import 'package:flutter/widgets.dart';

/// Tells the Library page whether the shell's sidebar is currently showing
/// the Library section links.
///
/// When it is not (phone bottom navigation, icon-only or auto-hiding desktop
/// sidebars, or a rail too short for the links), Library shows its own
/// section bar so every section stays reachable by pointer and touch.
///
/// [sidebarAllowsSections] is the shell's static decision (layout, sidebar
/// style); [sectionsFit] is reported by the sidebar after layout, because
/// only it knows whether the links fit its height.
class LibrarySectionNavigationScope
    extends InheritedNotifier<ValueNotifier<bool>> {
  const new({
    required this.sidebarAllowsSections,
    required ValueNotifier<bool> sectionsFit,
    required super.child,
    super.key,
  }) : super(notifier: sectionsFit);

  final bool sidebarAllowsSections;

  /// Whether the sidebar shows the Library section links. False without a
  /// scope, so Library falls back to its own section bar.
  static bool sidebarShowsSections(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LibrarySectionNavigationScope>();
    if (scope == null) {
      return false;
    }
    return scope.sidebarAllowsSections && (scope.notifier?.value ?? false);
  }

  @override
  bool updateShouldNotify(LibrarySectionNavigationScope oldWidget) {
    return oldWidget.sidebarAllowsSections != sidebarAllowsSections ||
        super.updateShouldNotify(oldWidget);
  }
}
