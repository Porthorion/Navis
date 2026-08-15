part of 'now_playing_screen.dart';

class _PlaybackSpeedSheet extends ConsumerStatefulWidget {
  const _PlaybackSpeedSheet({required this.initialSpeed});

  final double initialSpeed;

  @override
  ConsumerState<_PlaybackSpeedSheet> createState() =>
      _PlaybackSpeedSheetState();
}

class _PlaybackSpeedSheetState extends ConsumerState<_PlaybackSpeedSheet> {
  static const double _minPlaybackSpeed = 0.5;
  static const double _maxPlaybackSpeed = 2;
  double _speed = 1;
  bool _isSaving = false;
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    _speed = _normalizePlaybackSpeed(widget.initialSpeed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.playbackSettingsPlaybackSpeedLabel,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              formatPlaybackSpeed(_speed),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            Slider(
              value: _speed.clamp(_minPlaybackSpeed, _maxPlaybackSpeed),
              min: _minPlaybackSpeed,
              max: _maxPlaybackSpeed,
              divisions: 6,
              label: formatPlaybackSpeed(_speed),
              onChanged: _isSaving
                  ? null
                  : (value) {
                      setState(() => _speed = _normalizePlaybackSpeed(value));
                      _scheduleAutoSave();
                    },
            ),
            Text(
              l10n.playbackSettingsPlaybackSpeedSubtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(
                  onPressed: _isSaving
                      ? null
                      : () {
                          setState(() => _speed = 1);
                          _scheduleAutoSave();
                        },
                  child: Text(l10n.playbackSettingsResetAction),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _isSaving
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Text(l10n.playbackSettingsCloseAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _scheduleAutoSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 320),
      () => unawaited(_persistSpeed()),
    );
  }

  Future<void> _persistSpeed() async {
    if (_isSaving) {
      return;
    }
    setState(() => _isSaving = true);
    try {
      final settings =
          ref.read(appSettingsProvider).asData?.value ??
          const AppSettingsModel.defaults();
      await ref
          .read(settingsRepositoryProvider)
          .saveSettings(
            settings.copyWith(playbackSpeed: _normalizePlaybackSpeed(_speed)),
          );
      final handler = ref.read(audioHandlerProvider);
      await handler?.setPlaybackSpeed(_normalizePlaybackSpeed(_speed));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  double _normalizePlaybackSpeed(double value) {
    final clamped = value.clamp(_minPlaybackSpeed, _maxPlaybackSpeed);
    return (clamped * 4).round() / 4;
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}
