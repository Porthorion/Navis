import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// The legibility gradient behind white text over artwork.
///
/// It is function, not decoration, so it stays under Flat. Only its colour
/// follows the style: [NavisColorStyleData.artworkScrim] is pure black for
/// Neutral and a near-black tint for the other styles. [alphas] are 0-255
/// alpha values spread over the gradient (evenly, or at [stops]).
class ArtworkScrim extends StatelessWidget {
  const new({
    required this.alphas,
    this.stops,
    this.begin = Alignment.topCenter,
    this.end = Alignment.bottomCenter,
    super.key,
  });

  final List<int> alphas;
  final List<double>? stops;
  final AlignmentGeometry begin;
  final AlignmentGeometry end;

  @override
  Widget build(BuildContext context) {
    final scrim = NavisColorStyleData.of(context).artworkScrim;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: begin,
          end: end,
          colors: <Color>[for (final a in alphas) scrim.withAlpha(a)],
          stops: stops,
        ),
      ),
    );
  }
}
