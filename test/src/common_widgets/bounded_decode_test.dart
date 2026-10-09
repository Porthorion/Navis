import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';

void main() {
  test('boundedDecode caps untrusted images with aspect-preserving fit', () {
    final inner = NetworkImage('https://example.test/a.png');
    final bounded = boundedDecode(inner) as ResizeImage;
    expect(bounded.imageProvider, inner);
    expect(bounded.width, kMaxArtworkDecodeEdge);
    expect(bounded.height, kMaxArtworkDecodeEdge);
    expect(bounded.policy, ResizeImagePolicy.fit);
  });

  test('boundedDecode honours a palette bound and null bounds', () {
    final inner = NetworkImage('https://example.test/a.png');
    final palette = boundedDecode(
      inner,
      width: kPaletteDecodeEdge,
      height: kPaletteDecodeEdge,
    ) as ResizeImage;
    expect(palette.width, kPaletteDecodeEdge);
    expect(boundedDecode(inner, width: null, height: null), inner);
  });
}
