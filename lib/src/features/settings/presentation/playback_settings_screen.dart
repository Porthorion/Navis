import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class PlaybackSettingsScreen extends ConsumerStatefulWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  ConsumerState<PlaybackSettingsScreen> createState() =>
      _PlaybackSettingsScreenState();
}

class _PlaybackSettingsScreenState
    extends ConsumerState<PlaybackSettingsScreen> {
  static const List<int?> _qualityOptions = <int?>[
    null,
    320,
    256,
    192,
    128,
    96,
  ];
  static const List<String?> _formatOptions = <String?>[
    null,
    'mp3',
    'aac',
    'opus',
  ];

  final _formKey = GlobalKey<FormState>();

  int? _wifiBitRate;
  String? _wifiFormat;
  int? _cellularBitRate;
  String? _cellularFormat;
  bool _scrobbleEnabled = true;
  bool _gaplessEnabled = true;
  bool _didHydrateForm = false;
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settingsAsync = ref.watch(appSettingsProvider);

    settingsAsync.whenData((settings) {
      if (_didHydrateForm) {
        return;
      }
      _didHydrateForm = true;
      _hydrate(settings);
    });

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsPlaybackTitle)),
      body: settingsAsync.when(
        data: (_) => _buildForm(context, l10n),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.playbackSettingsLoadError(error.toString()),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, AppLocalizations l10n) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.playbackSettingsWifiSectionTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: _wifiBitRate,
                decoration: InputDecoration(
                  labelText: l10n.playbackSettingsWifiQualityLabel,
                ),
                items: _qualityOptions
                    .map(
                      (value) => DropdownMenuItem<int?>(
                        value: value,
                        child: Text(_qualityLabel(l10n, value)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _wifiBitRate = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _wifiFormat,
                decoration: InputDecoration(
                  labelText: l10n.playbackSettingsWifiFormatLabel,
                ),
                items: _formatOptions
                    .map(
                      (value) => DropdownMenuItem<String?>(
                        value: value,
                        child: Text(_formatLabel(l10n, value)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _wifiFormat = value),
              ),
              const SizedBox(height: 24),
              Text(
                l10n.playbackSettingsCellularSectionTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: _cellularBitRate,
                decoration: InputDecoration(
                  labelText: l10n.playbackSettingsCellularQualityLabel,
                ),
                items: _qualityOptions
                    .map(
                      (value) => DropdownMenuItem<int?>(
                        value: value,
                        child: Text(_qualityLabel(l10n, value)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _cellularBitRate = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _cellularFormat,
                decoration: InputDecoration(
                  labelText: l10n.playbackSettingsCellularFormatLabel,
                ),
                items: _formatOptions
                    .map(
                      (value) => DropdownMenuItem<String?>(
                        value: value,
                        child: Text(_formatLabel(l10n, value)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _cellularFormat = value),
              ),
              const SizedBox(height: 24),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _scrobbleEnabled,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _scrobbleEnabled = value),
                title: Text(l10n.playbackSettingsScrobbleTitle),
                subtitle: Text(l10n.playbackSettingsScrobbleSubtitle),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _gaplessEnabled,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _gaplessEnabled = value),
                title: Text(l10n.playbackSettingsGaplessTitle),
                subtitle: Text(l10n.playbackSettingsGaplessSubtitle),
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton(
                      onPressed: _isSaving ? null : _save,
                      child: Text(l10n.playbackSettingsSaveAction),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _isSaving ? null : _resetDefaults,
                child: Text(l10n.playbackSettingsResetAction),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _qualityLabel(AppLocalizations l10n, int? value) {
    return value == null
        ? l10n.playbackSettingsQualityOriginal
        : l10n.playbackSettingsQualityKbps(value);
  }

  String _formatLabel(AppLocalizations l10n, String? value) {
    return value == null
        ? l10n.playbackSettingsFormatOriginal
        : value.toUpperCase();
  }

  void _hydrate(AppSettingsModel settings) {
    _wifiBitRate = settings.wifiMaxBitRate;
    _wifiFormat = settings.wifiFormat;
    _cellularBitRate = settings.cellularMaxBitRate;
    _cellularFormat = settings.cellularFormat;
    _scrobbleEnabled = settings.scrobbleEnabled;
    _gaplessEnabled = settings.gaplessEnabled;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final settings = AppSettingsModel(
        wifiMaxBitRate: _wifiBitRate,
        wifiFormat: _normalizeFormat(_wifiFormat),
        cellularMaxBitRate: _cellularBitRate,
        cellularFormat: _normalizeFormat(_cellularFormat),
        scrobbleEnabled: _scrobbleEnabled,
        gaplessEnabled: _gaplessEnabled,
        skipSilenceEnabled: false,
      );
      await ref.read(settingsRepositoryProvider).saveSettings(settings);
      final handler = ref.read(audioHandlerProvider);
      if (handler != null) {
        await handler.applyRuntimeSettings();
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.playbackSettingsSaveSuccess)),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.playbackSettingsSaveFailure(error.toString())),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _resetDefaults() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isSaving = true);
    try {
      await ref.read(settingsRepositoryProvider).resetDefaults();
      const defaults = AppSettingsModel.defaults();
      final handler = ref.read(audioHandlerProvider);
      if (handler != null) {
        await handler.applyRuntimeSettings();
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _hydrate(defaults);
        _didHydrateForm = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.playbackSettingsResetSuccess)),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.playbackSettingsResetFailure(error.toString())),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  String? _normalizeFormat(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.toLowerCase();
  }
}
