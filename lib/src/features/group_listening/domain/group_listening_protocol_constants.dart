const String voyageProtocolVersion = 'voyage-sync.v4alpha1';

/// Legacy shortened id some Voyage builds emit during rollout.
const String voyageProtocolVersionAlias = 'sync.v4alpha1';

const String voyageProtocolVersionV3 = voyageProtocolVersion;
const String voyageReplayResumeCapability = 'replay_resume';
const String voyageQueueEntryMetadataCapability = 'queue_entry_metadata';
const String voyagePortableTrackRefsCapability = 'portable_track_refs';

const Set<String> _supportedVoyageProtocolVersions = <String>{
  voyageProtocolVersion,
  voyageProtocolVersionAlias,
};

/// Whether [value] is a supported inbound Voyage protocol id.
bool isSupportedVoyageProtocolVersion(String? value) {
  final normalized = (value ?? '').trim();
  if (normalized.isEmpty) {
    return false;
  }
  return _supportedVoyageProtocolVersions.contains(normalized);
}

/// Whether a health/discovery list advertises a protocol Navis can use.
bool discoveryListsSupportedVoyageProtocol(Iterable<String> versions) {
  for (final version in versions) {
    if (isSupportedVoyageProtocolVersion(version)) {
      return true;
    }
  }
  return false;
}
