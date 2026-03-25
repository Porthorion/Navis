import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sets a deterministic viewport for adaptive widget tests.
void setAdaptiveTestViewport(
  WidgetTester tester,
  Size size, {
  double devicePixelRatio = 1.0,
}) {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
