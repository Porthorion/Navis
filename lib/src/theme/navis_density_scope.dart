import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';

/// Measurements that follow the Density setting, read by list rows.
@immutable
class NavisDensityData {
  const new(this.density);

  /// Roomy spacing; matches the layout from before Density existed.
  static const NavisDensityData comfortable = NavisDensityData(
    NavisDensity.comfortable,
  );

  final NavisDensity density;

  bool get compact => density == NavisDensity.compact;

  /// Cover size of track, playlist and artist list rows.
  double get listCover => compact ? 40 : 48;

  /// Minimum height of an artwork track row.
  double get trackRowMinHeight => compact ? 52 : 64;

  /// Vertical padding of a track row.
  double get trackRowVerticalPadding => compact ? 4 : 8;

  /// Default padding of a track row.
  EdgeInsets get trackRowPadding =>
      EdgeInsets.symmetric(horizontal: 12, vertical: trackRowVerticalPadding);
}

/// Provides the app-wide Density to list rows without threading flags through
/// constructors. Absent (tests, isolated widgets) means comfortable.
class NavisDensityScope extends InheritedWidget {
  const new({required this.density, required super.child, super.key});

  final NavisDensity density;

  static NavisDensityData of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<NavisDensityScope>();
    return scope == null
        ? NavisDensityData.comfortable
        : NavisDensityData(scope.density);
  }

  @override
  bool updateShouldNotify(NavisDensityScope oldWidget) =>
      oldWidget.density != density;
}
