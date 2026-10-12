import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/marquee_text.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/common_widgets/notice_icon_disc.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Whether the offline banner is tucked away into [ShellOfflineChip].
///
/// Set by the banner's close button, and automatically when the reachability
/// state stops showing the retry banner (after repeated failures). Cleared
/// when the server is no longer offline, so the next outage shows the banner
/// again.
final shellOfflineBannerDismissedProvider =
    NotifierProvider<ShellOfflineBannerDismissed, bool>(
      ShellOfflineBannerDismissed.new,
    );

class ShellOfflineBannerDismissed extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<ServerReachabilityState>(serverReachabilityControllerProvider, (
      previous,
      next,
    ) {
      if (next.status != ServerReachabilityStatus.offline) {
        state = false;
      } else if ((previous?.showRetryBanner ?? true) && !next.showRetryBanner) {
        state = true;
      }
    });
    final reachability = ref.read(serverReachabilityControllerProvider);
    return reachability.status == ServerReachabilityStatus.offline &&
        !reachability.showRetryBanner;
  }

  void dismiss() => state = true;

  void expand() => state = false;
}

/// Drives the shell's offline banner for everything below it.
///
/// One animation reveals and hides the banner, and the shell also positions
/// its app notices from it (through [ShellOfflineBannerExtentBuilder]), so a
/// notice follows the banner frame by frame instead of jumping over it while
/// it collapses. The last message is kept while the banner animates away.
class ShellOfflineBannerScope extends StatefulWidget {
  const new({
    super.key,
    required this.visible,
    required this.message,
    required this.child,
  });

  final bool visible;
  final String message;
  final Widget child;

  static _ShellOfflineBannerInherited _of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_ShellOfflineBannerInherited>();
    assert(scope != null, 'No ShellOfflineBannerScope above this widget.');
    return scope!;
  }

  @override
  State<ShellOfflineBannerScope> createState() =>
      _ShellOfflineBannerScopeState();
}

class _ShellOfflineBannerScopeState extends State<ShellOfflineBannerScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final CurvedAnimation _curvedReveal = CurvedAnimation(
    parent: _reveal,
    curve: Curves.easeOutCubic,
  );
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
  void didUpdateWidget(covariant ShellOfflineBannerScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) {
      _message = widget.message;
    }
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _reveal.forward();
      } else {
        _reveal.reverse();
      }
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
    return _ShellOfflineBannerInherited(
      reveal: _curvedReveal,
      message: _message,
      child: widget.child,
    );
  }
}

class _ShellOfflineBannerInherited extends InheritedWidget {
  const new({
    required this.reveal,
    required this.message,
    required super.child,
  });

  final Animation<double> reveal;
  final String message;

  @override
  bool updateShouldNotify(_ShellOfflineBannerInherited oldWidget) =>
      reveal != oldWidget.reveal || message != oldWidget.message;
}

/// Rebuilds with the banner's current content height, from 0 when hidden to
/// [ShellOfflineBanner.contentHeight] when shown, following its animation.
///
/// The extent assumes a one-line banner; a message wrapped by a very large
/// text scale makes the banner taller than this.
class ShellOfflineBannerExtentBuilder extends StatelessWidget {
  const new({super.key, required this.builder});

  final Widget Function(BuildContext context, double extent) builder;

  @override
  Widget build(BuildContext context) {
    final reveal = ShellOfflineBannerScope._of(context).reveal;
    return AnimatedBuilder(
      animation: reveal,
      builder: (context, _) =>
          builder(context, ShellOfflineBanner.contentHeight * reveal.value),
    );
  }
}

/// Puts the offline banner above [child] and hands it the top inset.
///
/// The shell runs edge to edge, so the banner sits under the status bar and
/// pads its own content below it. While the banner is on screen, [child]
/// sees no top padding, so pages keep using `SafeArea` and primary `AppBar`s
/// without adding the status bar height a second time.
///
/// Only the content part of the banner animates. The status bar strip
/// appears and disappears together with the padding it replaces, so pages
/// never jump by the status bar height. Needs a [ShellOfflineBannerScope]
/// above it.
class ShellOfflineBannerFrame extends StatefulWidget {
  const new({super.key, required this.child});

  final Widget child;

  @override
  State<ShellOfflineBannerFrame> createState() =>
      _ShellOfflineBannerFrameState();
}

class _ShellOfflineBannerFrameState extends State<ShellOfflineBannerFrame> {
  Animation<double>? _reveal;
  // The banner stays present while it animates away.
  bool _present = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reveal = ShellOfflineBannerScope._of(context).reveal;
    if (!identical(reveal, _reveal)) {
      _reveal
        ?..removeStatusListener(_onRevealStatus)
        ..removeListener(_onReveal);
      _reveal = reveal
        ..addStatusListener(_onRevealStatus)
        ..addListener(_onReveal);
      _present = _isPresent(reveal);
    }
  }

  // Presence follows the value, not the dismissed status: a zero-length
  // (reduced motion) animation sets the value before its status, and a
  // controller created at its upper bound never reports the jump to
  // dismissed. A starting animation is present before its value moves.
  static bool _isPresent(Animation<double> reveal) =>
      reveal.value > 0 || reveal.isAnimating;

  void _onRevealStatus(AnimationStatus _) => _onReveal();

  void _onReveal() {
    final present = _isPresent(_reveal!);
    if (present != _present && mounted) {
      setState(() => _present = present);
    }
  }

  @override
  void dispose() {
    _reveal
      ?..removeStatusListener(_onRevealStatus)
      ..removeListener(_onReveal);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ShellOfflineBannerScope._of(context);
    return Column(
      children: <Widget>[
        if (_present)
          ShellOfflineBanner(message: scope.message, reveal: scope.reveal),
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
  static const Key dismissKey = ValueKey<String>('shell-offline-dismiss');

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
    final tokens = NavisTokens.of(context);
    final radius = NavisShapeData.of(context).lgAll;
    final flat = NavisColorStyleData.of(context).flatSurfaces;
    // A tile-like strip: the banner row is inset and rounded, and its height
    // (tile plus vertical inset) is [ShellOfflineBanner.contentHeight].
    final content = ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ShellOfflineBanner.contentHeight,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NavisSpace.md,
          vertical: NavisSpace.xxs,
        ),
        child: Material(
          color: flat ? Colors.transparent : colors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: flat
                ? BorderSide(color: colors.outlineVariant)
                : BorderSide.none,
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(
              start: NavisSpace.xs,
              end: NavisSpace.xxs,
            ),
            child: Row(
              children: <Widget>[
                NoticeIconDisc(
                  icon: Icons.cloud_off_outlined,
                  size: 32,
                  iconSize: 18,
                  fill: tokens.quietWarningContainer,
                  ink: tokens.onQuietWarningContainer,
                ),
                const SizedBox(width: NavisSpace.sm),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    // A message wider than the banner scrolls instead of
                    // ending in an ellipsis.
                    child: MarqueeText(
                      widget.message,
                      style:
                          theme.textTheme.labelLarge?.copyWith(
                            color: colors.onSurface,
                          ) ??
                          TextStyle(color: colors.onSurface),
                    ),
                  ),
                ),
                const SizedBox(width: NavisSpace.xs),
                FilledButton(
                  key: ShellOfflineBanner.retryKey,
                  onPressed: _retrying ? null : _retry,
                  style: NavisColorStyleData.tonalStyleOf(context).copyWith(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const WidgetStatePropertyAll<Size>(
                      Size(0, 32),
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: _retrying
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.commonRetry),
                ),
                IconButton(
                  key: ShellOfflineBanner.dismissKey,
                  tooltip: l10n.updateDismiss,
                  onPressed: () => ref
                      .read(shellOfflineBannerDismissedProvider.notifier)
                      .dismiss(),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  style: IconButton.styleFrom(
                    foregroundColor: colors.onSurfaceVariant,
                    fixedSize: const Size.square(32),
                    minimumSize: const Size.square(32),
                    padding: EdgeInsets.zero,
                    // Compact: the banner row is a fixed 48 px.
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final reveal = widget.reveal;
    return Material(
      key: ShellOfflineBanner.bannerKey,
      color: Colors.transparent,
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

/// The small "Offline" chip shown while the offline banner is dismissed.
///
/// It floats over the content (place it in a [Stack]) and takes no layout
/// space; tapping it expands the banner again.
class ShellOfflineChip extends ConsumerWidget {
  const new({super.key});

  static const Key chipKey = ValueKey<String>('shell-offline-chip');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final tokens = NavisTokens.of(context);
    return Semantics(
      button: true,
      label: l10n.serverOfflineBanner,
      excludeSemantics: true,
      child: Material(
        key: chipKey,
        color: tokens.quietWarningContainer,
        elevation: 2,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () =>
              ref.read(shellOfflineBannerDismissedProvider.notifier).expand(),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(8, 2, 10, 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.cloud_off_outlined,
                  size: 14,
                  color: tokens.onQuietWarningContainer,
                ),
                const SizedBox(width: NavisSpace.xxs),
                Text(
                  l10n.serverOfflineChip,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: tokens.onQuietWarningContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
