import 'package:material_ui/material_ui.dart';
import 'package:navis/src/app.dart';

const testNavisApp = NavisApp(splashFactory: NoSplash.splashFactory);

ThemeData testTheme([ThemeData? base]) {
  return (base ?? ThemeData()).copyWith(splashFactory: NoSplash.splashFactory);
}
