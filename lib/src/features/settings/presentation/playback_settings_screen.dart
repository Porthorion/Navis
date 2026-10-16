import 'package:navis/src/features/equalizer/presentation/eq_entry.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_panel.dart';
import 'package:navis/src/common_widgets/async_body.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

class PlaybackSettingsScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<PlaybackSettingsScreen> createState() =>
      _PlaybackSettingsScreenState();
}

class _PlaybackSettingsScreenState
    extends ConsumerState<PlaybackSettingsScreen> {
  static const double _minReplayGainPreamp = -6;
  static const double _maxReplayGainPreamp = 6;
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
    'vorbis',
  ];

  final _formKey = GlobalKey<FormState>();

  int? _wifiBitRate;
  String? _wifiFormat;
  int? _cellularBitRate;
  String? _cellularFormat;
  bool _cachedPlaybackFirst = false;
  bool _scrobbleEnabled = true;
  bool _gaplessEnabled = true;
  bool _fullscreenModeLyrics = false;
  bool _albumQueueEnabled = false;
  bool _likedQueueEnabled = false;
  bool _matchFlowEnabled = false;

  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 5;
  String _crossfadeType = 'normal';
  String _replayGainMode = 'off';
  double _replayGainPreamp = 0;
  bool _didHydrateForm = false;
  bool _isSaving = false;
  bool _isAutoSaving = false;
  bool _pendingAutosave = false;
  bool _experimentalExpanded = false;
  String _lastSavedSignature = '';
  Timer? _autosaveDebounce;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settingsAsync = ref.watch(appSettingsProvider);
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    settingsAsync.whenData((settings) {
      if (_didHydrateForm) {
        return;
      }
      _didHydrateForm = true;
      _hydrate(settings);
    });

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !desktopMode,
        leading: desktopMode
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    NavService.back(context, fallback: AppRoutes.settings),
              )
            : null,
        title: Text(l10n.settingsPlaybackTitle),
      ),
      body: AsyncBody(
        value: settingsAsync,
        data: (_) => _buildForm(context, l10n),
        errorTitle: l10n.playbackSettingsLoadError,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
    );
  }

  Widget _buildForm(BuildContext context, AppLocalizations l10n) {
    _scheduleAutosave();
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            desktopMode ? 24 : 16,
            desktopMode ? 24 : 16,
            desktopMode ? 24 : 16,
            16,
          ),
          children: <Widget>[
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const EqualizerEntry(),
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _cachedPlaybackFirst,
                    onChanged: _isSaving
                        ? null
                        : (value) =>
                              setState(() => _cachedPlaybackFirst = value),
                    title: Text(l10n.playbackSettingsCachedFirstTitle),
                    subtitle: Text(l10n.playbackSettingsCachedFirstSubtitle),
                  ),
                  const SizedBox(height: 24),
                  SwitchListTile(
                    key: const ValueKey('playbackSettingsScrobbleToggle'),
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
                    value: _albumQueueEnabled,
                    onChanged: _isSaving
                        ? null
                        : (value) => setState(() => _albumQueueEnabled = value),
                    title: Text(l10n.playbackSettingsAlbumQueueTitle),
                    subtitle: Text(l10n.playbackSettingsAlbumQueueSubtitle),
                  ),
                  if (_albumQueueEnabled)
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _likedQueueEnabled,
                        onChanged: _isSaving
                            ? null
                            : (value) =>
                                  setState(() => _likedQueueEnabled = value),
                        title: Text(l10n.playbackSettingsLikedQueueTitle),
                        subtitle: Text(l10n.playbackSettingsLikedQueueSubtitle),
                      ),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _gaplessEnabled,
                    onChanged: _isSaving ? null : _setGaplessEnabled,
                    title: Text(l10n.playbackSettingsGaplessTitle),
                    subtitle: Text(l10n.playbackSettingsGaplessSubtitle),
                  ),
                  if (_gaplessEnabled) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _crossfadeEnabled,
                            onChanged: _isSaving ? null : _setCrossfadeEnabled,
                            title: Text(
                              l10n.playbackSettingsCrossfadeEnableTitle,
                            ),
                            subtitle: Text(
                              l10n.playbackSettingsCrossfadeEnableSubtitle,
                            ),
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
                                      () => _crossfadeDurationSeconds = value
                                          .round(),
                                    ),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue: _crossfadeType,
                              decoration: InputDecoration(
                                labelText:
                                    l10n.playbackSettingsCrossfadeTypeLabel,
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 'normal',
                                  child: Text(
                                    l10n.playbackSettingsCrossfadeTypeNormal,
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'smart',
                                  child: Text(
                                    l10n.playbackSettingsCrossfadeTypeSmart,
                                  ),
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
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline,
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _fullscreenModeLyrics,
                    onChanged: _isSaving
                        ? null
                        : (value) =>
                              setState(() => _fullscreenModeLyrics = value),
                    title: Text(l10n.playbackSettingsFullscreenLyricsTitle),
                    subtitle: Text(
                      l10n.playbackSettingsFullscreenLyricsSubtitle,
                    ),
                  ),
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
                              () => _replayGainPreamp =
                                  _normalizeReplayGainPreamp(value),
                            ),
                    ),
                    Text(
                      l10n.playbackSettingsReplayGainPreampSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const PlaybackAdjustmentPanel(),
                  const SizedBox(height: 24),
                  _buildExperimentalSection(context, l10n),
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
        ),
      ),
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

  Widget _buildExperimentalSection(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: NavisShapeData.of(context).mdAll,
      child: Column(
        children: <Widget>[
          InkWell(
            borderRadius: NavisShapeData.of(context).mdAll,
            onTap: () {
              setState(() {
                _experimentalExpanded = !_experimentalExpanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.science_outlined,
                    size: 22,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.playbackSettingsExperimentalTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  AnimatedRotation(
                    turns: _experimentalExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ],
              ),
            ),
          ),
          ClipRect(
            child: AnimatedAlign(
              alignment: Alignment.topCenter,
              heightFactor: _experimentalExpanded ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: _experimentalExpanded ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                  child: Column(
                    children: _buildExperimentalControls(context, l10n),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildExperimentalControls(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    return <Widget>[
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _matchFlowEnabled,
        onChanged: _isSaving
            ? null
            : (value) => setState(() => _matchFlowEnabled = value),
        title: Text(l10n.matchFlowTitle),
        subtitle: Text(l10n.matchFlowPlaybackSettingsSubtitle),
      ),
      if (_matchFlowEnabled)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.account_tree_outlined),
          title: Text(l10n.matchFlowManageTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => NavService.openMatchFlow(context, ref),
        ),
    ];
  }

  void _hydrate(AppSettingsModel settings) {
    _wifiBitRate = settings.wifiMaxBitRate;
    _wifiFormat = settings.wifiFormat;
    _cellularBitRate = settings.cellularMaxBitRate;
    _cellularFormat = settings.cellularFormat;
    _cachedPlaybackFirst = settings.cachedPlaybackFirst;
    _scrobbleEnabled = settings.scrobbleEnabled;
    _gaplessEnabled = settings.gaplessEnabled || settings.crossfadeEnabled;
    _fullscreenModeLyrics = settings.skipSilenceEnabled;
    _albumQueueEnabled = settings.albumQueueEnabled;
    _likedQueueEnabled = settings.likedQueueEnabled;
    _matchFlowEnabled = settings.matchFlowEnabled;

    _crossfadeEnabled = settings.crossfadeEnabled;
    _crossfadeDurationSeconds = settings.crossfadeDurationSeconds;
    _crossfadeType = settings.crossfadeType;
    _replayGainMode = settings.replayGainMode;
    _replayGainPreamp = _normalizeReplayGainPreamp(settings.replayGainPreamp);
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
      _cachedPlaybackFirst,
      _scrobbleEnabled,
      _gaplessEnabled,
      _fullscreenModeLyrics,

      _crossfadeEnabled,
      _crossfadeDurationSeconds,
      _crossfadeType,
      _replayGainMode,
      _replayGainPreamp,
      _albumQueueEnabled,
      _likedQueueEnabled,
      _matchFlowEnabled,
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
      final wifiFormat = _normalizeFormat(_wifiFormat);
      final cellularFormat = _normalizeFormat(_cellularFormat);
      // Copy the stored row so fields owned by other screens (integrations,
      // ListenBrainz, sync and desktop volume) survive this general save.
      // Appearance and Home sections are protected by targeted-only writers.
      final settings = currentSettings.copyWith(
        wifiMaxBitRate: _wifiBitRate,
        clearWifiBitRate: _wifiBitRate == null,
        wifiFormat: wifiFormat,
        clearWifiFormat: wifiFormat == null,
        cellularMaxBitRate: _cellularBitRate,
        clearCellularBitRate: _cellularBitRate == null,
        cellularFormat: cellularFormat,
        clearCellularFormat: cellularFormat == null,
        cachedPlaybackFirst: _cachedPlaybackFirst,
        scrobbleEnabled: _scrobbleEnabled,
        gaplessEnabled: _gaplessEnabled || _crossfadeEnabled,
        skipSilenceEnabled: _fullscreenModeLyrics,
        crossfadeEnabled: _crossfadeEnabled,
        crossfadeDurationSeconds: _crossfadeDurationSeconds,
        crossfadeType: _crossfadeType,
        replayGainMode: _replayGainMode,
        replayGainPreamp: _normalizeReplayGainPreamp(_replayGainPreamp),
        albumQueueEnabled: _albumQueueEnabled,
        matchFlowEnabled: _matchFlowEnabled,
        likedQueueEnabled: _likedQueueEnabled,
      );
      await ref.read(settingsRepositoryProvider).saveSettings(settings);
      final handler = ref.read(audioHandlerProvider);
      if (handler != null) {
        await handler.applyRuntimeSettings();
      }
      _lastSavedSignature = signature;
    } on Object {
      if (!mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context)!;
      showAppNotice(
        context,
        message: l10n.playbackSettingsSaveFailure,
        level: AppNoticeLevel.error,
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
      await ref
          .read(playbackAdjustmentsProvider.notifier)
          .selectPreset(PlaybackPreset.noneId);
      await ref.read(equalizerProvider.notifier).reset();
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
        _lastSavedSignature = _formSignature();
      });
      showAppNotice(
        context,
        message: l10n.playbackSettingsResetSuccess,
        level: AppNoticeLevel.success,
      );
    } on Object {
      if (!mounted) {
        return;
      }
      showAppNotice(
        context,
        message: l10n.playbackSettingsResetFailure,
        level: AppNoticeLevel.error,
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

  double _normalizeReplayGainPreamp(double value) {
    return value.clamp(_minReplayGainPreamp, _maxReplayGainPreamp);
  }

  @override
  void dispose() {
    _autosaveDebounce?.cancel();
    if (_didHydrateForm) {
      final signature = _formSignature();
      if (signature != _lastSavedSignature) {
        unawaited(_persistAutosave(signature));
      }
    }
    super.dispose();
  }
}
