import 'package:flutter/foundation.dart';
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
  bool _equalizerEnabled = false;
  List<double> _equalizerBandGains = List<double>.filled(5, 0);
  bool _loudnessEnabled = false;
  double _loudnessTargetGainDb = 0;
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 5;
  String _crossfadeType = 'normal';
  bool _didHydrateForm = false;
  bool _isSaving = false;

  bool get _supportsAndroidDsp =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
              if (_supportsAndroidDsp) ...<Widget>[
                const SizedBox(height: 24),
                Text(
                  l10n.playbackSettingsAndroidDspSectionTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _equalizerEnabled,
                  onChanged: _isSaving
                      ? null
                      : (value) => setState(() => _equalizerEnabled = value),
                  title: Text(l10n.playbackSettingsEqualizerTitle),
                  subtitle: Text(l10n.playbackSettingsEqualizerSubtitle),
                ),
                if (_equalizerEnabled)
                  ...List<Widget>.generate(_equalizerBandGains.length, (
                    index,
                  ) {
                    final value = _equalizerBandGains[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          l10n.playbackSettingsEqualizerBandLabel(index + 1),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Slider(
                          value: value.clamp(-12, 12),
                          min: -12,
                          max: 12,
                          divisions: 24,
                          label: value.toStringAsFixed(1),
                          onChanged: _isSaving
                              ? null
                              : (nextValue) {
                                  setState(() {
                                    _equalizerBandGains[index] = nextValue;
                                  });
                                },
                        ),
                      ],
                    );
                  }),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _loudnessEnabled,
                  onChanged: _isSaving
                      ? null
                      : (value) => setState(() => _loudnessEnabled = value),
                  title: Text(l10n.playbackSettingsLoudnessTitle),
                  subtitle: Text(l10n.playbackSettingsLoudnessSubtitle),
                ),
                if (_loudnessEnabled)
                  Slider(
                    value: _loudnessTargetGainDb.clamp(0, 20),
                    min: 0,
                    max: 20,
                    divisions: 20,
                    label: _loudnessTargetGainDb.toStringAsFixed(0),
                    onChanged: _isSaving
                        ? null
                        : (value) =>
                              setState(() => _loudnessTargetGainDb = value),
                  ),
              ],
              // ── Cross-fade section ─────────────────────────────────────
              const SizedBox(height: 24),
              Text(
                l10n.playbackSettingsCrossfadeSectionTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _crossfadeEnabled,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _crossfadeEnabled = value),
                title: Text(l10n.playbackSettingsCrossfadeEnableTitle),
                subtitle: Text(l10n.playbackSettingsCrossfadeEnableSubtitle),
              ),
              if (_crossfadeEnabled) ...[
                Text(
                  l10n.playbackSettingsCrossfadeDurationLabel(
                    _crossfadeDurationSeconds,
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: _crossfadeDurationSeconds.toDouble(),
                  min: 1,
                  max: 12,
                  divisions: 11,
                  label: '${_crossfadeDurationSeconds}s',
                  onChanged: _isSaving
                      ? null
                      : (value) => setState(
                          () => _crossfadeDurationSeconds = value.round(),
                        ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _crossfadeType,
                  decoration: InputDecoration(
                    labelText: l10n.playbackSettingsCrossfadeTypeLabel,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'normal',
                      child: Text(l10n.playbackSettingsCrossfadeTypeNormal),
                    ),
                    DropdownMenuItem(
                      value: 'smart',
                      child: Text(l10n.playbackSettingsCrossfadeTypeSmart),
                    ),
                  ],
                  onChanged: _isSaving
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() => _crossfadeType = value);
                          }
                        },
                ),
                const SizedBox(height: 4),
                Text(
                  _crossfadeType == 'smart'
                      ? l10n.playbackSettingsCrossfadeTypeSmartDescription
                      : l10n.playbackSettingsCrossfadeTypeNormalDescription,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
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
    _equalizerEnabled = settings.equalizerEnabled;
    _equalizerBandGains = _normalizeBandGains(settings.equalizerBandGains);
    _loudnessEnabled = settings.loudnessEnabled;
    _loudnessTargetGainDb = settings.loudnessTargetGainDb;
    _crossfadeEnabled = settings.crossfadeEnabled;
    _crossfadeDurationSeconds = settings.crossfadeDurationSeconds;
    _crossfadeType = settings.crossfadeType;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final currentSettings =
          ref.read(appSettingsProvider).asData?.value ??
          const AppSettingsModel.defaults();
      final settings = AppSettingsModel(
        wifiMaxBitRate: _wifiBitRate,
        wifiFormat: _normalizeFormat(_wifiFormat),
        cellularMaxBitRate: _cellularBitRate,
        cellularFormat: _normalizeFormat(_cellularFormat),
        scrobbleEnabled: _scrobbleEnabled,
        gaplessEnabled: _gaplessEnabled,
        skipSilenceEnabled: false,
        showRadioPage: ref.read(showRadioPageProvider),
        showPlaylistsPage: ref.read(showPlaylistsPageProvider),
        showArtistsPage: ref.read(showArtistsPageProvider),
        equalizerEnabled: _equalizerEnabled,
        equalizerBandGains: _normalizeBandGains(_equalizerBandGains),
        loudnessEnabled: _loudnessEnabled,
        loudnessTargetGainDb: _loudnessTargetGainDb,
        wifiOnlyDownloads: ref.read(wifiOnlyDownloadsProvider),
        themeMode: ref.read(themeModeProvider),
        colorSchemeSeed: ref.read(colorSchemeSeedProvider),
        crossfadeEnabled: _crossfadeEnabled,
        crossfadeDurationSeconds: _crossfadeDurationSeconds,
        crossfadeType: _crossfadeType,
        artTintedNowPlaying: ref.read(artTintedNowPlayingProvider),
        updateCheckEnabled: currentSettings.updateCheckEnabled,
        updateChannel: currentSettings.updateChannel,
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

  List<double> _normalizeBandGains(List<double> values) {
    if (values.length >= 5) {
      return values.take(5).toList(growable: false);
    }
    return <double>[
      ...values,
      ...List<double>.filled(5 - values.length, 0),
    ];
  }
}
