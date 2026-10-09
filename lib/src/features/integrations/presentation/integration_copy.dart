import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

// Copy shared by Settings › Integrations and the onboarding Integrations
// step, so both describe each service the same way.

/// The heading shown for [service]. Brand names are not translated.
String integrationServiceName(
  IntegrationService service,
  AppLocalizations l10n,
) => switch (service) {
  IntegrationService.updates => l10n.integrationsServiceUpdates,
  IntegrationService.radioMetadata => l10n.integrationsServiceRadio,
  IntegrationService.serverLinkedArtwork => l10n.integrationsServiceArtwork,
  IntegrationService.deezer ||
  IntegrationService.lastFm ||
  IntegrationService.listenBrainz ||
  IntegrationService.lrclib ||
  IntegrationService.autoEq => service.displayName,
};

/// The one line saying what [service] receives and from or to where.
String integrationServiceDescription(
  IntegrationService service,
  AppLocalizations l10n,
) {
  final host = service.displayHost ?? '';
  return switch (service) {
    IntegrationService.deezer => l10n.integrationsDeezerSends(host),
    IntegrationService.lastFm => l10n.integrationsLastFmSends(host),
    IntegrationService.listenBrainz => l10n.integrationsListenBrainzSends(host),
    IntegrationService.lrclib => l10n.integrationsLrclibSends(host),
    IntegrationService.updates => l10n.integrationsUpdatesSends(host),
    IntegrationService.autoEq => l10n.integrationsAutoEqSends(host),
    IntegrationService.radioMetadata => l10n.integrationsRadioSends,
    IntegrationService.serverLinkedArtwork => l10n.integrationsArtworkSends,
  };
}

/// Title and short description of a feature switch.
({String title, String subtitle}) integrationFeatureCopy(
  IntegrationFeature feature,
  AppLocalizations l10n,
) => switch (feature) {
  IntegrationFeature.deezerTopSongs => (
    title: l10n.integrationsFeatureDeezerTopSongsTitle,
    subtitle: l10n.integrationsFeatureDeezerTopSongsSubtitle,
  ),
  IntegrationFeature.deezerArtistImages => (
    title: l10n.integrationsFeatureDeezerArtistImagesTitle,
    subtitle: l10n.integrationsFeatureDeezerArtistImagesSubtitle,
  ),
  IntegrationFeature.deezerSimilarArtists => (
    title: l10n.integrationsFeatureDeezerSimilarArtistsTitle,
    subtitle: l10n.integrationsFeatureDeezerSimilarArtistsSubtitle,
  ),
  IntegrationFeature.deezerMissingAlbums => (
    title: l10n.integrationsFeatureDeezerMissingAlbumsTitle,
    subtitle: l10n.integrationsFeatureDeezerMissingAlbumsSubtitle,
  ),
  IntegrationFeature.deezerNewReleases => (
    title: l10n.integrationsFeatureDeezerNewReleasesTitle,
    subtitle: l10n.integrationsFeatureDeezerNewReleasesSubtitle,
  ),
  IntegrationFeature.deezerTrending => (
    title: l10n.integrationsFeatureDeezerTrendingTitle,
    subtitle: l10n.integrationsFeatureDeezerTrendingSubtitle,
  ),
  IntegrationFeature.lastFmSameVibes => (
    title: l10n.integrationsFeatureLastFmSameVibesTitle,
    subtitle: l10n.integrationsFeatureLastFmSameVibesSubtitle,
  ),
  IntegrationFeature.lastFmRadio => (
    title: l10n.integrationsFeatureLastFmRadioTitle,
    subtitle: l10n.integrationsFeatureLastFmRadioSubtitle,
  ),
  IntegrationFeature.lastFmTopSongs => (
    title: l10n.integrationsFeatureLastFmTopSongsTitle,
    subtitle: l10n.integrationsFeatureLastFmTopSongsSubtitle,
  ),
  IntegrationFeature.listenBrainzScrobbling => (
    title: l10n.integrationsFeatureListenBrainzScrobblingTitle,
    subtitle: l10n.integrationsFeatureListenBrainzScrobblingSubtitle,
  ),
  IntegrationFeature.listenBrainzFeedback => (
    title: l10n.integrationsFeatureListenBrainzFeedbackTitle,
    subtitle: l10n.integrationsFeatureListenBrainzFeedbackSubtitle,
  ),
  IntegrationFeature.listenBrainzWeeklyPlaylists => (
    title: l10n.integrationsFeatureListenBrainzWeeklyPlaylistsTitle,
    subtitle: l10n.integrationsFeatureListenBrainzWeeklyPlaylistsSubtitle,
  ),
  IntegrationFeature.lrclibLyrics => (
    title: l10n.integrationsFeatureLrclibLyricsTitle,
    subtitle: l10n.integrationsFeatureLrclibLyricsSubtitle,
  ),
  IntegrationFeature.updatesAutomatic => (
    title: l10n.integrationsFeatureUpdatesAutomaticTitle,
    subtitle: l10n.integrationsFeatureUpdatesAutomaticSubtitle,
  ),
  IntegrationFeature.autoEqCatalogue => (
    title: l10n.integrationsFeatureAutoEqCatalogueTitle,
    subtitle: l10n.integrationsFeatureAutoEqCatalogueSubtitle,
  ),
  IntegrationFeature.radioNowPlaying => (
    title: l10n.integrationsFeatureRadioNowPlayingTitle,
    subtitle: l10n.integrationsFeatureRadioNowPlayingSubtitle,
  ),
  IntegrationFeature.artworkServerLinked => (
    title: l10n.integrationsFeatureArtworkServerLinkedTitle,
    subtitle: l10n.integrationsFeatureArtworkServerLinkedSubtitle,
  ),
};

/// Why a switch cannot be changed, shown in place of its description.
String integrationLockReasonText(
  IntegrationLockReason reason, {
  required IntegrationService service,
  required String serviceName,
  required AppLocalizations l10n,
}) => switch (reason) {
  IntegrationLockReason.masterOff => l10n.integrationsLockedMasterOff,
  IntegrationLockReason.serviceOff => l10n.integrationsLockedServiceOff(
    serviceName,
  ),
  IntegrationLockReason.notVerified =>
    service.verification == IntegrationVerification.listenBrainzToken
        ? l10n.integrationsLockedNeedsListenBrainzToken
        : l10n.integrationsLockedNeedsLastFmKey,
};
