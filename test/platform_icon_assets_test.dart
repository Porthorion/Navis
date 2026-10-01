import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

Future<int> _pixelAlpha(String path, {required bool atCenter}) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  expect(data, isNotNull, reason: 'Could not decode $path');
  final x = atCenter ? image.width ~/ 2 : 0;
  final y = atCenter ? image.height ~/ 2 : 0;
  final offset = ((y * image.width) + x) * 4;
  final alpha = data!.getUint8(offset + 3);
  image.dispose();
  codec.dispose();
  return alpha;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'desktop and legacy Android icons have transparent outer canvases',
    () async {
      const transparentIcons = <String>[
        'lib/src/icon/Navis_App_Icon.png',
        'linux/packaging/icons/hicolor/256x256/apps/navis.png',
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
        'android/app/src/main/res/mipmap-mdpi/ic_launcher_navis.png',
      ];

      for (final path in transparentIcons) {
        expect(
          await _pixelAlpha(path, atCenter: false),
          0,
          reason: '$path has a baked background',
        );
        expect(
          await _pixelAlpha(path, atCenter: true),
          255,
          reason: '$path lost the centred badge',
        );
      }
    },
  );

  test('Android adaptive background is transparent', () {
    final colors = File('android/app/src/main/res/values/colors.xml')
        .readAsStringSync();
    expect(
      colors,
      contains('<color name="ic_launcher_background">#00000000</color>'),
    );
  });

  test('iOS icon keeps its required opaque canvas', () async {
    const icon =
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/'
        'Icon-App-1024x1024@1x.png';
    expect(await _pixelAlpha(icon, atCenter: false), 255);
  });
}
