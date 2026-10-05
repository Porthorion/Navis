enum CatalogSource { onServer, external }

CatalogSource classifyCatalogSource({required String id, bool? apiIsExternal}) {
  if (apiIsExternal != null) {
    return apiIsExternal ? CatalogSource.external : CatalogSource.onServer;
  }

  final normalizedId = id.trim().toLowerCase();
  return normalizedId.startsWith('ext-') ||
          normalizedId.startsWith('remote-') ||
          normalizedId.startsWith('pl-deezer-')
      ? CatalogSource.external
      : CatalogSource.onServer;
}

bool isExternalCatalogSource({required String id, bool? apiIsExternal}) =>
    classifyCatalogSource(id: id, apiIsExternal: apiIsExternal) ==
    CatalogSource.external;

/// The id a server with a Deezer-backed remote catalogue (Octo-Fiesta) gives
/// the Deezer album [deezerId]. Opening it asks that server, never Deezer.
String remoteDeezerAlbumId(int deezerId) => 'ext-deezer-album-$deezerId';

/// The id a server with a Deezer-backed remote catalogue gives the Deezer
/// artist [deezerId].
String remoteDeezerArtistId(int deezerId) => 'ext-deezer-artist-$deezerId';
