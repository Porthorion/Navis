import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/navigation_history_provider.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/theme/navis_theme.dart';

/// Root application widget for Navis.
class NavisApp extends ConsumerStatefulWidget {
  /// Creates a new [NavisApp].
  const NavisApp({
    super.key,
    this.requirePlaybackBootstrap = false,
    this.schedulePlaybackBootstrap = true,
  });

  final bool requirePlaybackBootstrap;
  final bool schedulePlaybackBootstrap;

  @override
  ConsumerState<NavisApp> createState() => _NavisAppState();
}

class _NavisAppState extends ConsumerState<NavisApp> {
  bool _didScheduleBootstrap = false;
  final ShortcutManager _desktopActivationShortcutManager =
      _DesktopActivationShortcutManager();

  @override
  void initState() {
    super.initState();
    if (!widget.requirePlaybackBootstrap ||
        !widget.schedulePlaybackBootstrap ||
        _didScheduleBootstrap) {
      return;
    }
    _didScheduleBootstrap = true;
    unawaited(
      Future<void>.microtask(() {
        if (!mounted) return;
        ref.read(audioBootstrapControllerProvider.notifier).ensureInitialized();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final themeModeName = ref.watch(themeModeProvider);
    final colorSeed = ref.watch(effectiveColorSchemeSeedProvider);
    final localeCode = ref.watch(appLocaleProvider);
    final seedColor = colorSeed != null ? Color(colorSeed) : Colors.blue;
    final resolvedThemeMode = resolveThemeMode(themeModeName);
    final isOled = themeModeName == 'oled';
    final appLocale = localeCode == null || localeCode.trim().isEmpty
        ? null
        : Locale(localeCode);

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) =>
          AppLocalizations.of(context)?.appName ?? 'Navis',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: appLocale,
      theme: buildLightTheme(seedColor),
      darkTheme: isOled ? buildOledTheme(seedColor) : buildDarkTheme(seedColor),
      themeMode: resolvedThemeMode,
      builder: (context, child) {
        var content = _wrapWithDesktopInputBoundary(
          child ?? const SizedBox.shrink(),
        );
        if (widget.requirePlaybackBootstrap) {
          content = _AppBootstrapOverlay(child: content);
        }
        return content;
      },
      routerConfig: router,
    );
  }

  Widget _wrapWithDesktopInputBoundary(Widget child) {
    if (!isDesktopRuntime) {
      return child;
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        FocusManager.instance.primaryFocus?.unfocus();
        if (event.buttons & kBackMouseButton != 0) {
          ref
              .read(navigationHistoryProvider.notifier)
              .navigateBack(ref.read(appRouterProvider));
        } else if (event.buttons & kForwardMouseButton != 0) {
          ref
              .read(navigationHistoryProvider.notifier)
              .navigateForward(ref.read(appRouterProvider));
        }
      },
      child: Shortcuts.manager(
        manager: _desktopActivationShortcutManager,
        child: child,
      ),
    );
  }
}

class _DesktopActivationShortcutManager extends ShortcutManager {
  _DesktopActivationShortcutManager()
    : super(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.space):
              DoNothingAndStopPropagationIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        },
      );

  @override
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    if (desktopCommandBlockedByTextInput()) {
      return KeyEventResult.ignored;
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    return super.handleKeypress(focusedContext ?? context, event);
  }
}

// ---------------------------------------------------------------------------
// Bootstrap splash overlay — shown on app start while the audio engine
// initialises.  Rendered on top of the fully-themed MaterialApp.router so it
// inherits the user's chosen theme automatically.
// ---------------------------------------------------------------------------

class _AppBootstrapOverlay extends ConsumerStatefulWidget {
  const _AppBootstrapOverlay({required this.child});

  final Widget child;

  @override
  ConsumerState<_AppBootstrapOverlay> createState() =>
      _AppBootstrapOverlayState();
}

class _AppBootstrapOverlayState extends ConsumerState<_AppBootstrapOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _ringController;
  late final AnimationController _exitController;
  late final Animation<double> _ringFill;
  late final Animation<double> _exit;

  bool _overlayDismissed = false;
  bool _completionTriggered = false;

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    _ringFill = CurvedAnimation(
      parent: _ringController,
      curve: Curves.easeOutCubic,
    );
    _exit = CurvedAnimation(parent: _exitController, curve: Curves.easeInCubic);
    _exitController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _overlayDismissed = true);
      }
    });
  }

  @override
  void dispose() {
    _ringController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  void _onBootstrapReady() {
    if (_completionTriggered) return;
    _completionTriggered = true;
    unawaited(
      _ringController.forward().then<void>((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 260));
        if (mounted) unawaited(_exitController.forward());
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_overlayDismissed) return widget.child;

    final bootstrap = ref.watch(audioBootstrapControllerProvider);

    if (bootstrap.status == AudioBootstrapStatus.ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onBootstrapReady();
      });
    }

    final isFailed = bootstrap.status == AudioBootstrapStatus.failed;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        widget.child,
        AnimatedBuilder(
          animation: Listenable.merge([_ringFill, _exit]),
          builder: (context, _) => _BootstrapSplashScreen(
            ringFill: _ringFill.value,
            isRingCompleting: _completionTriggered,
            exitProgress: _exit.value,
            isFailed: isFailed,
            onRetry: ref.read(audioBootstrapControllerProvider.notifier).retry,
          ),
        ),
      ],
    );
  }
}

// Same optical-centre offsets used by the home sync logo.
const double _assetCenterOffsetX = 12.5 / 1024.0;
const double _assetCenterOffsetY = 3.5 / 1024.0;

class _BootstrapSplashScreen extends StatelessWidget {
  const _BootstrapSplashScreen({
    required this.ringFill,
    required this.isRingCompleting,
    required this.exitProgress,
    required this.isFailed,
    required this.onRetry,
  });

  // 0.0–1.0 value for the determinate ring once completion is triggered.
  final double ringFill;

  // True once the bootstrap has completed and the ring is filling.
  final bool isRingCompleting;

  // 0.0 = fully visible, 1.0 = fully gone (exit animation).
  final double exitProgress;

  final bool isFailed;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final screenSize = MediaQuery.sizeOf(context);

    final logoSize = screenSize.width >= 1200 ? 80.0 : 120.0;
    final strokeWidth = (logoSize * 0.055).clamp(2.2, 5.2);
    final ringColor = isFailed ? colorScheme.error : colorScheme.primary;
    final ringTrackColor = isFailed
        ? colorScheme.error.withValues(alpha: 0.15)
        : colorScheme.primary.withValues(alpha: 0.12);
    final iconOffset = Offset(
      -(logoSize * _assetCenterOffsetX),
      -(logoSize * _assetCenterOffsetY),
    );

    // Exit animation — logo lifts upward and fades out.
    final opacity = (1.0 - exitProgress).clamp(0.0, 1.0);
    final translateY = -screenSize.height * 0.35 * exitProgress;
    final scale = 1.0 - 0.15 * exitProgress;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Solid background that fades away.
        Opacity(
          opacity: opacity,
          child: ColoredBox(color: bgColor),
        ),
        // Logo + ring that lifts toward the top while fading.
        Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: Transform.scale(
              scale: scale,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Stack(
                      alignment: Alignment.center,
                      children: <Widget>[
                        SizedBox.square(
                          dimension: logoSize,
                          child: Padding(
                            padding: EdgeInsets.all(strokeWidth / 2),
                            child: CircularProgressIndicator(
                              value: isRingCompleting
                                  ? ringFill.clamp(0.0, 1.0)
                                  : null,
                              strokeWidth: strokeWidth,
                              color: ringColor,
                              backgroundColor: ringTrackColor,
                            ),
                          ),
                        ),
                        Transform.translate(
                          offset: iconOffset,
                          child: NavisIcon(
                            size: logoSize,
                            tintWithAccent: true,
                          ),
                        ),
                      ],
                    ),
                    if (isFailed) ...<Widget>[
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          children: <Widget>[
                            Text(
                              AppLocalizations.of(
                                context,
                              )!.playbackBootstrapFailedTitle,
                              style: Theme.of(context).textTheme.titleLarge,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              AppLocalizations.of(
                                context,
                              )!.playbackBootstrapFailedSubtitle,
                              style: Theme.of(context).textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: onRetry,
                              child: Text(
                                AppLocalizations.of(
                                  context,
                                )!.playbackBootstrapRetryAction,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
