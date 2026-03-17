import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/format_utils.dart';

class PlaybackSettingsScreen extends ConsumerStatefulWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  ConsumerState<PlaybackSettingsScreen> createState() =>
      _PlaybackSettingsScreenState();
}

class _PlaybackSettingsScreenState
    extends ConsumerState<PlaybackSettingsScreen> {
  static const double _minReplayGainPreamp = -6;
  static const double _maxReplayGainPreamp = 6;
  static const double _minPlaybackSpeed = 0.5;
  static const double _maxPlaybackSpeed = 2;
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
  bool _useLrclib = true;
  bool _gaplessEnabled = true;
  bool _fullscreenModeLyrics = false;
  bool _equalizerEnabled = false;
  List<double> _equalizerBandGains = List<double>.filled(5, 0);
  bool _loudnessEnabled = false;
  double _loudnessTargetGainDb = 0;
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 5;
  String _crossfadeType = 'normal';
  String _replayGainMode = 'off';
  double _replayGainPreamp = 0;
  double _playbackSpeed = 1;
  bool _didHydrateForm = false;
  bool _isSaving = false;
  bool _isAutoSaving = false;
  bool _pendingAutosave = false;
  String _lastSavedSignature = '';
  Timer? _autosaveDebounce;

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
    _scheduleAutosave();

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
                value: _useLrclib,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _useLrclib = value),
                title: Text(l10n.playbackSettingsLrclibTitle),
                subtitle: Text(l10n.playbackSettingsLrclibSubtitle),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _gaplessEnabled,
                onChanged: _isSaving ? null : _setGaplessEnabled,
                title: Text(l10n.playbackSettingsGaplessTitle),
                subtitle: Text(l10n.playbackSettingsGaplessSubtitle),
              ),
              if (_gaplessEnabled) ...<Widget>[
                // ── Cross-fade section ───────────────────────────────────
                const SizedBox(height: 24),
                Text(
                  l10n.playbackSettingsCrossfadeSectionTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _crossfadeEnabled,
                  onChanged: _isSaving ? null : _setCrossfadeEnabled,
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
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _fullscreenModeLyrics,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _fullscreenModeLyrics = value),
                title: const Text('Fullscreen Mode Lyrics'),
                subtitle: const Text(
                  'Open lyrics in fullscreen directly from Now Playing.',
                ),
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
              // ── ReplayGain section ─────────────────────────────────────
              const SizedBox(height: 24),
              Text(
                l10n.playbackSettingsReplayGainSectionTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _replayGainMode,
                decoration: InputDecoration(
                  labelText: l10n.playbackSettingsReplayGainModeLabel,
                ),
                items: [
                  DropdownMenuItem(
                    value: 'off',
                    child: Text(l10n.playbackSettingsReplayGainModeOff),
                  ),
                  DropdownMenuItem(
                    value: 'track',
                    child: Text(l10n.playbackSettingsReplayGainModeTrack),
                  ),
                  DropdownMenuItem(
                    value: 'album',
                    child: Text(l10n.playbackSettingsReplayGainModeAlbum),
                  ),
                ],
                onChanged: _isSaving
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _replayGainMode = value);
                        }
                      },
              ),
              const SizedBox(height: 4),
              Text(
                _replayGainMode == 'off'
                    ? l10n.playbackSettingsReplayGainModeOffDescription
                    : _replayGainMode == 'track'
                    ? l10n.playbackSettingsReplayGainModeTrackDescription
                    : l10n.playbackSettingsReplayGainModeAlbumDescription,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              if (_replayGainMode != 'off') ...[
                const SizedBox(height: 12),
                Text(
                  '${l10n.playbackSettingsReplayGainPreampLabel}: '
                  '${_replayGainPreamp.toStringAsFixed(1)} dB',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: _replayGainPreamp.clamp(
                    _minReplayGainPreamp,
                    _maxReplayGainPreamp,
                  ),
                  min: _minReplayGainPreamp,
                  max: _maxReplayGainPreamp,
                  divisions: 24,
                  label: '${_replayGainPreamp.toStringAsFixed(1)} dB',
                  onChanged: _isSaving
                      ? null
                      : (value) => setState(
                          () => _replayGainPreamp = _normalizeReplayGainPreamp(
                            value,
                          ),
                        ),
                ),
                Text(
                  l10n.playbackSettingsReplayGainPreampSubtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
              // ── Playback Speed section ─────────────────────────────────
              const SizedBox(height: 24),
              Text(
                l10n.playbackSettingsPlaybackSpeedLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                formatPlaybackSpeed(_playbackSpeed),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Slider(
                value: _playbackSpeed.clamp(
                  _minPlaybackSpeed,
                  _maxPlaybackSpeed,
                ),
                min: _minPlaybackSpeed,
                max: _maxPlaybackSpeed,
                divisions: 6,
                label: formatPlaybackSpeed(_playbackSpeed),
                onChanged: _isSaving
                    ? null
                    : (value) => setState(
                        () => _playbackSpeed = _normalizePlaybackSpeed(value),
                      ),
              ),
              Text(
                l10n.playbackSettingsPlaybackSpeedSubtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  if (_isAutoSaving)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  if (_isAutoSaving) const SizedBox(width: 8),
                  Text(
                    _isAutoSaving
                        ? 'Saving changes...'
                        : 'Changes save automatically',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    _useLrclib = settings.useLrclib;
    _gaplessEnabled = settings.gaplessEnabled || settings.crossfadeEnabled;
    _fullscreenModeLyrics = settings.skipSilenceEnabled;
    _equalizerEnabled = settings.equalizerEnabled;
    _equalizerBandGains = _normalizeBandGains(settings.equalizerBandGains);
    _loudnessEnabled = settings.loudnessEnabled;
    _loudnessTargetGainDb = settings.loudnessTargetGainDb;
    _crossfadeEnabled = settings.crossfadeEnabled;
    _crossfadeDurationSeconds = settings.crossfadeDurationSeconds;
    _crossfadeType = settings.crossfadeType;
    _replayGainMode = settings.replayGainMode;
    _replayGainPreamp = _normalizeReplayGainPreamp(settings.replayGainPreamp);
    _playbackSpeed = _normalizePlaybackSpeed(settings.playbackSpeed);
    _lastSavedSignature = _formSignature();
  }

  void _scheduleAutosave() {
    if (!_didHydrateForm || _isSaving) {
      return;
    }
    final signature = _formSignature();
    if (signature == _lastSavedSignature) {
      return;
    }
    _autosaveDebounce?.cancel();
    _autosaveDebounce = Timer(
      const Duration(milliseconds: 420),
      () => unawaited(_persistAutosave(signature)),
    );
  }

  String _formSignature() {
    return <Object?>[
      _wifiBitRate,
      _wifiFormat,
      _cellularBitRate,
      _cellularFormat,
      _scrobbleEnabled,
      _useLrclib,
      _gaplessEnabled,
      _fullscreenModeLyrics,
      _equalizerEnabled,
      ..._equalizerBandGains,
      _loudnessEnabled,
      _loudnessTargetGainDb,
      _crossfadeEnabled,
      _crossfadeDurationSeconds,
      _crossfadeType,
      _replayGainMode,
      _replayGainPreamp,
      _playbackSpeed,
    ].join('|');
  }

  Future<void> _persistAutosave(String signature) async {
    if (_isAutoSaving) {
      _pendingAutosave = true;
      return;
    }
    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (mounted) {
      setState(() => _isAutoSaving = true);
    }
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
        gaplessEnabled: _gaplessEnabled || _crossfadeEnabled,
        skipSilenceEnabled: _fullscreenModeLyrics,
        showRadioPage: ref.read(showRadioPageProvider),
        showPlaylistsPage: ref.read(showPlaylistsPageProvider),
        showArtistsPage: ref.read(showArtistsPageProvider),
        showLikedPage: ref.read(showLikedPageProvider),
        equalizerEnabled: _equalizerEnabled,
        equalizerBandGains: _normalizeBandGains(_equalizerBandGains),
        loudnessEnabled: _loudnessEnabled,
        loudnessTargetGainDb: _loudnessTargetGainDb,
        wifiOnlyDownloads: ref.read(wifiOnlyDownloadsProvider),
        autoDownloadStarredOnWifi: currentSettings.autoDownloadStarredOnWifi,
        themeMode: ref.read(themeModeProvider),
        colorSchemeSeed: ref.read(colorSchemeSeedProvider),
        appLocale: ref.read(appLocaleProvider),
        crossfadeEnabled: _crossfadeEnabled,
        crossfadeDurationSeconds: _crossfadeDurationSeconds,
        crossfadeType: _crossfadeType,
        artTintedNowPlaying: ref.read(artTintedNowPlayingProvider),
        dynamicAlbumColorEnabled: currentSettings.dynamicAlbumColorEnabled,
        updateCheckEnabled: currentSettings.updateCheckEnabled,
        updateChannel: currentSettings.updateChannel,
        audioMuseServerUrl: currentSettings.audioMuseServerUrl,
        audioMuseApiKey: currentSettings.audioMuseApiKey,
        audioMuseEnabled: currentSettings.audioMuseEnabled,
        syncIntervalMinutes: currentSettings.syncIntervalMinutes,
        useLrclib: _useLrclib,
        replayGainMode: _replayGainMode,
        replayGainPreamp: _normalizeReplayGainPreamp(_replayGainPreamp),
        playbackSpeed: _normalizePlaybackSpeed(_playbackSpeed),
        albumGridDensity: currentSettings.albumGridDensity,
        coverArtShape: currentSettings.coverArtShape,
        nowPlayingArtShape: currentSettings.nowPlayingArtShape,
        artistCardShape: currentSettings.artistCardShape,
        artistViewMode: currentSettings.artistViewMode,
        homeSectionOrder: currentSettings.homeSectionOrder,
        homeSectionsHidden: currentSettings.homeSectionsHidden,
      );
      await ref.read(settingsRepositoryProvider).saveSettings(settings);
      final handler = ref.read(audioHandlerProvider);
      if (handler != null) {
        await handler.applyRuntimeSettings();
        await handler.setPlaybackSpeed(settings.playbackSpeed);
      }
      _lastSavedSignature = signature;
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context)!;
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.playbackSettingsSaveFailure(error.toString())),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isAutoSaving = false);
      }
      if (_pendingAutosave) {
        _pendingAutosave = false;
        _scheduleAutosave();
      }
    }
  }

  void _setGaplessEnabled(bool value) {
    setState(() {
      _gaplessEnabled = value;
      if (!value && _crossfadeEnabled) {
        _crossfadeEnabled = false;
      }
    });
  }

  void _setCrossfadeEnabled(bool value) {
    setState(() {
      _crossfadeEnabled = value;
      if (value) {
        _gaplessEnabled = true;
      }
    });
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
        await handler.setPlaybackSpeed(defaults.playbackSpeed);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _hydrate(defaults);
        _didHydrateForm = true;
        _lastSavedSignature = _formSignature();
      });
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.playbackSettingsResetSuccess)),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      AppNoticeMessenger.of(context).showSnackBar(
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

  double _normalizeReplayGainPreamp(double value) {
    return value.clamp(_minReplayGainPreamp, _maxReplayGainPreamp);
  }

  double _normalizePlaybackSpeed(double value) {
    final clamped = value.clamp(_minPlaybackSpeed, _maxPlaybackSpeed);
    return (clamped * 4).round() / 4;
  }

  @override
  void dispose() {
    _autosaveDebounce?.cancel();
    super.dispose();
  }
}
