import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a hosted HTTP(S) URL in the platform browser.
Future<bool> launchExternalHttpUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !isHostedHttpUri(uri)) return false;
  return await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Whether a MusicBrainz identifier is a UUID safe to embed in a URL path.
bool isMusicBrainzUuid(String? id) =>
    id != null &&
    RegExp(
      r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
    ).hasMatch(id);
