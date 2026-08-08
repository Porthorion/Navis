enum CatalogSource { onServer, external }

CatalogSource classifyCatalogSource({
  required String id,
  bool? apiIsExternal,
}) {
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

bool isExternalCatalogSource({
  required String id,
  bool? apiIsExternal,
}) =>
    classifyCatalogSource(id: id, apiIsExternal: apiIsExternal) ==
    CatalogSource.external;
