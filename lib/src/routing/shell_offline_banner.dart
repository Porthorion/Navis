import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Puts the offline banner above [child] and hands it the top inset.
///
/// The shell runs edge to edge, so the banner sits under the status bar and
/// pads its own content below it. While the banner is on screen, [child]
/// sees no top padding, so pages keep using `SafeArea` and primary `AppBar`s
/// without adding the status bar height a second time.
///
/// Only the content part of the banner animates. The status bar strip
/// appears and disappears together with the padding it replaces, so pages
/// never jump by the status bar height.
class ShellOfflineBannerFrame extends StatefulWidget {
  const new({
    super.key,
    required this.visible,
    required this.message,
    required this.child,
  });

  final bool visible;
  final String message;
  final Widget child;

  @override
  State<ShellOfflineBannerFrame> createState() =>
      _ShellOfflineBannerFrameState();
}

class _ShellOfflineBannerFrameState extends State<ShellOfflineBannerFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    value: widget.visible ? 1 : 0,
  )..addStatusListener(_onRevealStatus);
  late final CurvedAnimation _curvedReveal = CurvedAnimation(
    parent: _reveal,
    curve: Curves.easeOutCubic,
  );
  // The banner stays present while it animates away.
  late bool _present = widget.visible;
  // The last message shown, kept while the banner animates away.
  late String _message = widget.message;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = MotionPolicy.of(context).surface;
    _reveal
      ..duration = duration
      ..reverseDuration = duration;
  }

  @override
  void didUpdateWidget(covariant ShellOfflineBannerFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) {
      _message = widget.message;
      _present = true;
    }
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _reveal.forward();
      } else {
        _reveal.reverse();
      }
    }
  }

  void _onRevealStatus(AnimationStatus status) {
    final present = !status.isDismissed;
    if (present != _present && mounted) {
      setState(() => _present = present);
    }
  }

  @override
  void dispose() {
    _curvedReveal.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        if (_present)
          ShellOfflineBanner(message: _message, reveal: _curvedReveal),
        Expanded(
          // Always wrapped in the same widget type, so toggling the banner
          // never rebuilds the pages below it.
          child: MediaQuery.removePadding(
            context: context,
            removeTop: _present,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// The shell's offline banner: a status line with a Retry action.
class ShellOfflineBanner extends ConsumerStatefulWidget {
  const new({super.key, required this.message, this.reveal});

  final String message;

  /// Animates the content height; the status bar strip is never animated.
  final Animation<double>? reveal;

  /// Height of the banner below the status bar: one row with a full-size
  /// Retry target. App notices are placed below it while it is visible.
  static const double contentHeight = 48;

  static const Key bannerKey = ValueKey<String>('shell-offline-banner');
  static const Key retryKey = ValueKey<String>('shell-offline-retry');

  @override
  ConsumerState<ShellOfflineBanner> createState() => _ShellOfflineBannerState();
}

class _ShellOfflineBannerState extends ConsumerState<ShellOfflineBanner> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await ref.read(serverReachabilityControllerProvider.notifier).retryNow();
    } finally {
      if (mounted) {
        setState(() => _retrying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ShellOfflineBanner.contentHeight,
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: NavisSpace.md,
          end: NavisSpace.xxs,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: NavisSpace.sm),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  widget.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(width: NavisSpace.xs),
            TextButton(
              key: ShellOfflineBanner.retryKey,
              onPressed: _retrying ? null : _retry,
              child: _retrying
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
    final reveal = widget.reveal;
    return Material(
      key: ShellOfflineBanner.bannerKey,
      color: colors.surfaceContainerHigh,
      child: SafeArea(
        bottom: false,
        left: false,
        right: false,
        child: reveal == null
            ? content
            : SizeTransition(
                sizeFactor: reveal,
                alignment: AlignmentDirectional.bottomStart,
                child: content,
              ),
      ),
    );
  }
}
