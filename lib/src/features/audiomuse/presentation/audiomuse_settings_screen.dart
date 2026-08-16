import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/audiomuse/data/audiomuse_api_client.dart';
import 'package:navis/src/features/audiomuse/data/audiomuse_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';

class AudioMuseSettingsScreen extends ConsumerStatefulWidget {
  const AudioMuseSettingsScreen({super.key});

  @override
  ConsumerState<AudioMuseSettingsScreen> createState() =>
      _AudioMuseSettingsScreenState();
}

class _AudioMuseSettingsScreenState
    extends ConsumerState<AudioMuseSettingsScreen> {
  final _serverUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  bool _enabled = false;
  bool _isTesting = false;
  bool _initialized = false;

  @override
  void dispose() {
    _serverUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _initFromSettings(AppSettingsModel settings) {
    if (_initialized) return;
    _initialized = true;
    _enabled = settings.audioMuseEnabled;
    _serverUrlController.text = settings.audioMuseServerUrl ?? '';
    _apiKeyController.text = settings.audioMuseApiKey ?? '';
  }

  Future<void> _save() async {
    final repo = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    final serverUrl = _serverUrlController.text.trim();
    final apiKey = _apiKeyController.text.trim();
    await repo.saveSettings(
      current.copyWith(
        audioMuseEnabled: _enabled,
        audioMuseServerUrl: serverUrl.isEmpty ? null : serverUrl,
        audioMuseApiKey: apiKey.isEmpty ? null : apiKey,
        clearAudioMuseServerUrl: serverUrl.isEmpty,
        clearAudioMuseApiKey: apiKey.isEmpty,
      ),
    );
  }

  Future<void> _testConnection() async {
    setState(() => _isTesting = true);
    try {
      final url = _serverUrlController.text.trim();
      final apiKey = _apiKeyController.text.trim();
      if (url.isEmpty) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        showAppNotice(
          context,
          message: l10n.audioMuseTestConnectionFailed,
          level: AppNoticeLevel.error,
        );
        return;
      }
      final client = AudioMuseApiClient(
        baseUrl: url,
        apiKey: apiKey.isEmpty ? null : apiKey,
      );
      final repo = AudioMuseRepository(client);
      final health = await repo.testConnection();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      if (health.healthy) {
        showAppNotice(
          context,
          message: l10n.audioMuseTestConnectionSuccess(
            health.version ?? 'unknown',
          ),
          level: AppNoticeLevel.success,
        );
      } else {
        showAppNotice(
          context,
          message: l10n.audioMuseTestConnectionFailed,
          level: AppNoticeLevel.error,
        );
      }
    } on Object {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showAppNotice(
        context,
        message: l10n.audioMuseTestConnectionFailed,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settingsAsync = ref.watch(appSettingsProvider);
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !desktopMode,
        leading: desktopMode
            ? IconButton(
                tooltip: l10n.syncSettingsBackToSettings,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => NavService.returnToSettings(context, ref),
              )
            : null,
        title: Text(l10n.audioMuseSettingsTitle),
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => ErrorState(
          title: l10n.audioMuseSettingsLoadError,
          onRetry: () => ref.invalidate(appSettingsProvider),
        ),
        data: (settings) {
          _initFromSettings(settings);
          final content = ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: <Widget>[
              // ── Enable toggle ──────────────────────────────────────────
              SwitchListTile(
                title: Text(l10n.audioMuseEnabledLabel),
                subtitle: Text(l10n.audioMuseEnabledSubtitle),
                secondary: const Icon(Icons.auto_awesome),
                value: _enabled,
                onChanged: (value) {
                  setState(() => _enabled = value);
                  _save();
                },
              ),
              const Divider(),

              // ── Connection section ─────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  l10n.audioMuseConnectionSection,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (!_enabled)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    l10n.audioMuseDisabledHint,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
              if (_enabled) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: TextField(
                    controller: _serverUrlController,
                    decoration: InputDecoration(
                      labelText: l10n.audioMuseServerUrlLabel,
                      hintText: l10n.audioMuseServerUrlHint,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.link),
                    ),
                    keyboardType: TextInputType.url,
                    onChanged: (_) => _save(),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: TextField(
                    controller: _apiKeyController,
                    decoration: InputDecoration(
                      labelText: l10n.audioMuseApiKeyLabel,
                      hintText: l10n.audioMuseApiKeyHint,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.key),
                    ),
                    obscureText: true,
                    onChanged: (_) => _save(),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FilledButton.tonalIcon(
                    onPressed: _isTesting ? null : _testConnection,
                    icon: _isTesting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.science_outlined),
                    label: Text(l10n.audioMuseTestConnection),
                  ),
                ),
              ],
            ],
          );
          if (!desktopMode) return content;
          return SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: content,
              ),
            ),
          );
        },
      ),
    );
  }
}
