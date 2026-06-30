import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.privacyTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          _PrivacySection(
            title: 'Accounts and credentials',
            body:
                'Navis connects directly to the Subsonic or OpenSubsonic '
                'servers you configure. Server addresses and usernames are '
                'stored in the app database. Passwords and external service '
                'tokens are stored through the platform secure credential '
                'store when available.',
          ),
          _PrivacySection(
            title: 'External scrobbling',
            body:
                'If you enable ListenBrainz, Navis sends listening '
                'activity for played tracks to those services. This can include '
                'track title, artist, album, duration, play time, and now-playing '
                'status. ListenBrainz user tokens remain on your device.',
          ),
          _PrivacySection(
            title: 'Downloads and cache',
            body:
                'Offline downloads, playback cache, artwork, lyrics, and library '
                'metadata are stored on your device so playback and browsing can '
                'work without repeatedly fetching the same data. You can clear '
                'cache data from Settings.',
          ),
          _PrivacySection(
            title: 'Diagnostics',
            body:
                'Navis avoids logging raw credentials and redacts sensitive '
                'authentication values from diagnostics. Network errors may still '
                'include service names or non-secret request context needed to '
                'troubleshoot failures.',
          ),
          Text(
            'Navis does not operate a central account service for your music '
            'library. Data is exchanged with the servers and optional third-party '
            'services you configure.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacySection extends StatelessWidget {
  const _PrivacySection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(body, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
