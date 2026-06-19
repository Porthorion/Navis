import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:url_launcher/url_launcher.dart';

class ExternalServicesSettingsScreen extends ConsumerStatefulWidget {
  const ExternalServicesSettingsScreen({super.key});

  @override
  ConsumerState<ExternalServicesSettingsScreen> createState() =>
      _ExternalServicesSettingsScreenState();
}

class _ExternalServicesSettingsScreenState
    extends ConsumerState<ExternalServicesSettingsScreen> {
  final _lastFmApiKeyController = TextEditingController();
  final _listenBrainzTokenController = TextEditingController();
  bool _hydrated = false;
  bool _busy = false;
  String? _lastFmApiKeyError;
  String? _lastFmApiKeySuccess;

  @override
  void dispose() {
    _lastFmApiKeyController.dispose();
    _listenBrainzTokenController.dispose();
    super.dispose();
  }

  Future<void> _hydrate(AppSettingsModel settings) async {
    if (_hydrated) {
      return;
    }
    _hydrated = true;
    _lastFmApiKeyController.text = settings.lastFmApiKey ?? '';
    final store = ref.read(externalScrobbleCredentialStoreProvider);
    _listenBrainzTokenController.text =
        await store.readListenBrainzToken() ?? '';
    if (mounted) {
      setState(() {
        if ((settings.lastFmApiKey ?? '').trim().isNotEmpty) {
          _lastFmApiKeySuccess = 'Last.fm API key saved.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    settingsAsync.whenData((settings) => _hydrate(settings));
    return Scaffold(
      appBar: AppBar(title: const Text('External Services')),
      body: settingsAsync.when(
        data: (settings) => ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _buildLastFmCard(settings),
            const SizedBox(height: 12),
            _buildListenBrainzCard(settings),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(error.toString())),
      ),
    );
  }

  Widget _buildLastFmCard(AppSettingsModel settings) {
    final hasBundledKey = ref.watch(lastFmBundledKeyProvider);
    final apiKeyValid =
        hasBundledKey || (settings.lastFmApiKey?.trim().isNotEmpty ?? false);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.auto_awesome_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Last.fm',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (apiKeyValid)
                  Icon(Icons.check_circle, color: Colors.green.shade700),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              hasBundledKey
                  ? 'This build includes a Last.fm API key for recommendations.'
                  : 'Add a Last.fm API key to enable Last.fm-backed recommendations.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (!hasBundledKey) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                controller: _lastFmApiKeyController,
                decoration: InputDecoration(
                  labelText: 'API key',
                  border: const OutlineInputBorder(),
                  errorText: _lastFmApiKeyError,
                  helperText: _lastFmApiKeyError == null
                      ? _lastFmApiKeySuccess
                      : null,
                  helperStyle: TextStyle(color: Colors.green.shade700),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (!hasBundledKey)
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _saveLastFmKey(settings),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                  ),
                TextButton.icon(
                  onPressed: () => _open('https://www.last.fm/api/accounts'),
                  icon: const Icon(Icons.key_outlined),
                  label: const Text('Get API key'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListenBrainzCard(AppSettingsModel settings) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.hearing_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'ListenBrainz',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Switch(
                  value:
                      settings.listenBrainzScrobblingEnabled &&
                      settings.listenBrainzTokenValid,
                  onChanged: settings.listenBrainzTokenValid && !_busy
                      ? (value) => _saveSettings(
                          settings.copyWith(
                            listenBrainzScrobblingEnabled: value,
                          ),
                        )
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _listenBrainzTokenController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'User token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _validateListenBrainz(settings),
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Validate token'),
                ),
                TextButton.icon(
                  onPressed: () => _open('https://listenbrainz.org/settings/'),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Get Token'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              settings.listenBrainzTokenValid
                  ? 'Token validated'
                  : 'Token not validated',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveLastFmKey(AppSettingsModel settings) async {
    final apiKey = _lastFmApiKeyController.text.trim();
    setState(() => _busy = true);
    try {
      if (apiKey.isNotEmpty) {
        final result = await LastFmApiClient(
          apiKey: apiKey,
        ).validateApiKey();
        if (!result.valid) {
          setState(() {
            _lastFmApiKeyError = 'Invalid Last.fm API key.';
            _lastFmApiKeySuccess = null;
          });
          return;
        }
      }
      await _saveSettings(
        settings.copyWith(
          lastFmApiKey: apiKey.isEmpty ? null : apiKey,
          clearLastFmApiKey: apiKey.isEmpty,
          lastFmScrobblingEnabled: false,
          lastFmSessionConnected: false,
        ),
      );
      setState(() {
        _lastFmApiKeyError = null;
        _lastFmApiKeySuccess = apiKey.isEmpty ? null : 'Last.fm API key saved.';
      });
      _notice(
        apiKey.isEmpty ? 'Last.fm API key removed.' : 'Last.fm API key saved.',
      );
    } on LastFmApiException {
      setState(() {
        _lastFmApiKeyError = 'Could not validate this Last.fm API key.';
        _lastFmApiKeySuccess = null;
      });
    } on Object {
      _notice('Could not save the Last.fm API key. Try again later.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _validateListenBrainz(AppSettingsModel settings) async {
    final token = _listenBrainzTokenController.text.trim();
    if (token.isEmpty) {
      _notice('Enter the ListenBrainz user token first.');
      return;
    }
    setState(() => _busy = true);
    try {
      final details = await ListenBrainzApiClient().validateTokenDetails(token);
      if (details.valid) {
        await ref
            .read(externalScrobbleCredentialStoreProvider)
            .saveListenBrainzToken(token);
      } else {
        await ref
            .read(externalScrobbleCredentialStoreProvider)
            .clearListenBrainzToken();
      }
      await _saveSettings(
        settings.copyWith(
          listenBrainzTokenValid: details.valid,
          listenBrainzScrobblingEnabled: details.valid,
          listenBrainzUserName: details.userName,
          clearListenBrainzUserName: !details.valid,
        ),
      );
      _notice(
        details.valid ? 'ListenBrainz token validated.' : 'Token is not valid.',
      );
    } on Object {
      _notice('Could not validate the ListenBrainz token. Try again later.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _saveSettings(AppSettingsModel settings) {
    return ref.read(settingsRepositoryProvider).saveSettings(settings);
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _notice(String message) {
    if (!mounted) {
      return;
    }
    showAppNotice(context, message: message);
  }
}
