import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// TEMPORARY DESIGN EXPERIMENT: delete once the owner has chosen a treatment.
///
/// How text that sits on artwork stays readable when Flat rendering is on.
/// Flat off always keeps today's black scrim gradients.
enum FlatArtworkTextVariant {
  /// Keep the black scrim gradients under Flat (readability first).
  gradient,

  /// Replace each scrim with a solid caption band behind the text block.
  band,
}

/// TEMPORARY DESIGN EXPERIMENT: runtime switch between the two
/// [FlatArtworkTextVariant] treatments. Not persisted; delete with the enum
/// and the helpers below once one treatment is chosen.
final NotifierProvider<FlatArtworkTextVariantNotifier, FlatArtworkTextVariant>
flatArtworkTextVariantProvider =
    NotifierProvider<FlatArtworkTextVariantNotifier, FlatArtworkTextVariant>(
      FlatArtworkTextVariantNotifier.new,
    );

/// Holds the current [FlatArtworkTextVariant]; defaults to
/// [FlatArtworkTextVariant.gradient].
class FlatArtworkTextVariantNotifier extends Notifier<FlatArtworkTextVariant> {
  @override
  FlatArtworkTextVariant build() => FlatArtworkTextVariant.gradient;

  // A method, not a setter: callers use `.set(...)` like the app's other
  // notifiers.
  // ignore: use_setters_to_change_properties
  void set(FlatArtworkTextVariant variant) => state = variant;
}

/// Whether artwork text should use a caption band: Flat is on and the band
/// variant is selected.
bool useFlatArtworkBand(BuildContext context, WidgetRef ref) {
  return NavisColorStyleData.of(context).flat &&
      ref.watch(flatArtworkTextVariantProvider) == FlatArtworkTextVariant.band;
}

/// Text shadows for white text over artwork. The band variant drops them
/// because the band already provides the contrast.
List<Shadow>? artworkTextShadows(
  BuildContext context,
  WidgetRef ref,
  List<Shadow> shadows,
) {
  return useFlatArtworkBand(context, ref) ? null : shadows;
}

/// The scrim layer behind text over artwork: [gradient] normally and in
/// Flat's gradient variant, nothing in Flat's band variant (the text gets an
/// [ArtworkCaptionBand] instead).
class ArtworkScrim extends ConsumerWidget {
  const new({required this.gradient, super.key});

  final Gradient gradient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (useFlatArtworkBand(context, ref)) {
      return const SizedBox.shrink();
    }
    return DecoratedBox(decoration: BoxDecoration(gradient: gradient));
  }
}

/// Key of the solid caption band painted by [ArtworkCaptionBand].
const Key artworkCaptionBandKey = ValueKey<String>('artwork-caption-band');

/// Wraps a text block over artwork. In Flat's band variant it paints an
/// opaque black rectangle (62% alpha) behind [child] and its [padding];
/// otherwise it only applies [padding].
///
/// Black, not a themed surface, because text over artwork is always white
/// regardless of theme: a themed band would force theme-dependent text
/// colours and could drop below contrast on light themes.
class ArtworkCaptionBand extends ConsumerWidget {
  const new({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.bandPadding = const EdgeInsets.symmetric(vertical: 6),
    this.gradientHeadroom = 0,
    super.key,
  });

  final Widget child;

  /// The text's inset, applied in every mode.
  final EdgeInsetsGeometry padding;

  /// Extra room between the band edge and [padding], used only when the band
  /// is painted.
  final EdgeInsetsGeometry bandPadding;

  /// Room above the text that a scrim gradient needs to fade in; applied
  /// only when the band is not painted.
  final double gradientHeadroom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!useFlatArtworkBand(context, ref)) {
      return Padding(
        padding: padding.add(EdgeInsets.only(top: gradientHeadroom)),
        child: child,
      );
    }
    return DecoratedBox(
      key: artworkCaptionBandKey,
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62)),
      child: Padding(padding: padding.add(bandPadding), child: child),
    );
  }
}
