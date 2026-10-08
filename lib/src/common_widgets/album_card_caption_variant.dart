import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How an album card shows its title and artist.
///
/// TEMPORARY DESIGN EXPERIMENT: this enum, [albumCardCaptionVariantProvider]
/// and every `AlbumCardCaptionVariant` branch in `album_card.dart`,
/// `external_album_card.dart` and the grids/rails that host those cards exist
/// only so the product owner can compare treatments in screenshots. Remove
/// them, keeping the chosen variant, once one is picked.
enum AlbumCardCaptionVariant {
  /// Today's look: the cover fades into the page background and the text
  /// sits over the fade.
  overlayFade,

  /// The caption sits below the square cover on the page background.
  below,

  /// A short fade into a fully opaque page-background band holding the text.
  band,

  /// A black gradient with white text in every theme.
  darkScrim,
}

/// Notifier behind [albumCardCaptionVariantProvider].
class AlbumCardCaptionVariantNotifier
    extends Notifier<AlbumCardCaptionVariant> {
  @override
  AlbumCardCaptionVariant build() => AlbumCardCaptionVariant.overlayFade;

  // A named method, not a setter, so callers can tear it off.
  // ignore: use_setters_to_change_properties
  void set(AlbumCardCaptionVariant variant) => state = variant;
}

/// The active album-card caption variant (temporary design experiment, see
/// [AlbumCardCaptionVariant]).
final albumCardCaptionVariantProvider =
    NotifierProvider<AlbumCardCaptionVariantNotifier, AlbumCardCaptionVariant>(
      AlbumCardCaptionVariantNotifier.new,
    );
