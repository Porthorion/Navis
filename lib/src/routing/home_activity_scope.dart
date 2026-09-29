import 'package:flutter/widgets.dart';

/// Shell activity, including modal routes presented above a branch navigator.
class HomeActivityScope extends InheritedWidget {
  const HomeActivityScope({
    required this.active,
    required super.child,
    super.key,
  });
  final bool active;
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeActivityScope>()?.active ??
      true;
  @override
  bool updateShouldNotify(HomeActivityScope oldWidget) =>
      oldWidget.active != active;
}
