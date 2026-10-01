import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/navigation_history_provider.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_presentation_host.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/routing/navigation_service.dart';

/// Root application widget for Navis.
class NavisApp extends ConsumerStatefulWidget {
  /// Creates a new [NavisApp].
  const new({
    super.key,
    this.requirePlaybackBootstrap = false,
    this.schedulePlaybackBootstrap = true,
    this.splashFactory,
    this.onBootstrapOverlayDismissed,
  });

  final bool requirePlaybackBootstrap;
  final bool schedulePlaybackBootstrap;
  final InteractiveInkFeatureFactory? splashFactory;
  final VoidCallback? onBootstrapOverlayDismissed;

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
    if (isDesktopRuntime) {
      // Keep history recording from launch, not from the first Back press.
      ref.listen(navigationHistoryProvider, (_, _) {});
    }
    final themeModeName = ref.watch(themeModeProvider);
    final colorSeed = ref.watch(effectiveColorSchemeSeedProvider);
    final localeCode = ref.watch(appLocaleProvider);
    final seedColor = resolveColorSchemeSeedColor(colorSeed);
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
      theme: buildLightTheme(seedColor)
          .copyWith(splashFactory: widget.splashFactory),
      darkTheme:
          (isOled ? buildOledTheme(seedColor) : buildDarkTheme(seedColor))
              .copyWith(splashFactory: widget.splashFactory),
      themeMode: resolvedThemeMode,
      builder: (context, child) {
        var content = _wrapWithDesktopInputBoundary(
          child ?? const SizedBox.shrink(),
        );
        if (isDesktopRuntime) {
          content = DesktopPresentationHost(child: content);
        }
        if (widget.requirePlaybackBootstrap) {
          content = _AppBootstrapOverlay(
            onDismissed: widget.onBootstrapOverlayDismissed,
            child: content,
          );
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
          unawaited(NavService.navigateHistory(ref, forward: false));
        } else if (event.buttons & kForwardMouseButton != 0) {
          unawaited(NavService.navigateHistory(ref, forward: true));
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
  new()
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
  const new({required this.child, this.onDismissed});

  final Widget child;
  final VoidCallback? onDismissed;

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
  Timer? _recoveryTimer;
  bool _recoveryAvailable = false;
  bool _allowRouterWhilePlaybackUnavailable = false;
  bool _isRecovering = false;
  String? _recoveryError;

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
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onDismissed?.call();
        });
      }
    });
    _recoveryTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && !_overlayDismissed && !_completionTriggered) {
        setState(() => _recoveryAvailable = true);
      }
    });
  }

  @override
  void dispose() {
    _ringController.dispose();
    _exitController.dispose();
    _recoveryTimer?.cancel();
    super.dispose();
  }

  void _onBootstrapReady() {
    if (_completionTriggered) return;
    _completionTriggered = true;
    _recoveryTimer?.cancel();
    unawaited(
      _ringController.forward().then<void>((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 260));
        if (mounted) unawaited(_exitController.forward());
      }),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppLocalizations.of(dialogContext)!.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _runRecovery(
    Future<void> Function(PlaybackRecoveryService service) action,
  ) async {
    if (_isRecovering) {
      return;
    }
    setState(() {
      _isRecovering = true;
      _recoveryError = null;
    });
    try {
      await action(ref.read(playbackRecoveryServiceProvider));
    } on Object {
      if (mounted) {
        setState(
          () =>
              _recoveryError = AppLocalizations.of(context)!
                  .playbackRecoveryActionFailed,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isRecovering = false);
      }
    }
  }

  Future<void> _resetCache() async {
    final l10n = AppLocalizations.of(context)!;
    if (!await _confirm(
      title: l10n.playbackRecoveryResetConfirmTitle,
      body: l10n.playbackRecoveryResetConfirmBody,
      action: l10n.playbackRecoveryResetConfirmAction,
    )) {
      return;
    }
    await _runRecovery((service) => service.resetLibraryCacheAndRetry());
  }

  Future<void> _signOut({required bool wipeLocalData}) async {
    final l10n = AppLocalizations.of(context)!;
    if (wipeLocalData &&
        !await _confirm(
          title: l10n.playbackRecoveryWipeConfirmTitle,
          body: l10n.playbackRecoveryWipeConfirmBody,
          action: l10n.playbackRecoveryWipeConfirmAction,
        )) {
      return;
    }
    await _runRecovery((service) async {
      await service.signOut(wipeLocalData: wipeLocalData);
      if (mounted) {
        setState(() => _allowRouterWhilePlaybackUnavailable = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_overlayDismissed || _allowRouterWhilePlaybackUnavailable) {
      return widget.child;
    }

    final bootstrap = ref.watch(audioBootstrapControllerProvider);
    final hasAuthenticatedSession =
        ref.watch(serverConfigStateProvider).asData?.value != null;

    if (bootstrap.status == AudioBootstrapStatus.ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onBootstrapReady();
      });
    }

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
            showRecovery: _recoveryAvailable,
            hasAuthenticatedSession: hasAuthenticatedSession,
            isRecovering: _isRecovering,
            recoveryError: _recoveryError,
            onContinueToSignIn: () {
              _recoveryTimer?.cancel();
              setState(() => _allowRouterWhilePlaybackUnavailable = true);
            },
            onResetCache: _resetCache,
            onSignOutKeepData: () => _signOut(wipeLocalData: false),
            onSignOutWipeData: () => _signOut(wipeLocalData: true),
          ),
        ),
      ],
    );
  }
}

class _BootstrapSplashScreen extends StatelessWidget {
  const new({
    required this.ringFill,
    required this.isRingCompleting,
    required this.exitProgress,
    required this.showRecovery,
    required this.hasAuthenticatedSession,
    required this.isRecovering,
    required this.recoveryError,
    required this.onContinueToSignIn,
    required this.onResetCache,
    required this.onSignOutKeepData,
    required this.onSignOutWipeData,
  });

  // 0.0–1.0 value for the determinate ring once completion is triggered.
  final double ringFill;

  // True once the bootstrap has completed and the ring is filling.
  final bool isRingCompleting;

  // 0.0 = fully visible, 1.0 = fully gone (exit animation).
  final double exitProgress;
  final bool showRecovery;
  final bool hasAuthenticatedSession;
  final bool isRecovering;
  final String? recoveryError;
  final VoidCallback onContinueToSignIn;
  final VoidCallback onResetCache;
  final VoidCallback onSignOutKeepData;
  final VoidCallback onSignOutWipeData;

  @override
  Widget build(BuildContext context) {
    final accentColors = NavisAccentColors.of(context);
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final screenSize = MediaQuery.sizeOf(context);

    final logoSize = screenSize.width >= 1200 ? 80.0 : 120.0;
    final strokeWidth = (logoSize * 0.055).clamp(2.2, 5.2);
    final ringColor = accentColors.brand;
    final ringTrackColor = accentColors.brandTrack;
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
                        NavisIcon(
                          key: const ValueKey<String>('bootstrap-logo'),
                          size: logoSize,
                          tintWithAccent: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        children: <Widget>[
                          Text(
                            showRecovery
                                ? AppLocalizations.of(context)!
                                      .playbackBootstrapRecoveryTitle
                                : AppLocalizations.of(context)!
                                      .playbackBootstrapLoadingTitle,
                            style: Theme.of(context).textTheme.titleLarge,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            showRecovery
                                ? AppLocalizations.of(context)!
                                      .playbackBootstrapRecoverySubtitle
                                : AppLocalizations.of(context)!
                                      .playbackBootstrapLoadingSubtitle,
                            style: Theme.of(context).textTheme.bodyMedium,
                            textAlign: TextAlign.center,
                          ),
                          if (showRecovery) ...<Widget>[
                            const SizedBox(height: 20),
                            if (isRecovering)
                              const CircularProgressIndicator()
                            else if (hasAuthenticatedSession) ...<Widget>[
                              OutlinedButton(
                                onPressed: onResetCache,
                                child: Text(
                                  AppLocalizations.of(context)!
                                      .playbackRecoveryResetCache,
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: onSignOutKeepData,
                                child: Text(
                                  AppLocalizations.of(context)!
                                      .serverSettingsSignOutKeepData,
                                ),
                              ),
                              TextButton(
                                onPressed: onSignOutWipeData,
                                child: Text(
                                  AppLocalizations.of(context)!
                                      .serverSettingsSignOutWipeData,
                                ),
                              ),
                            ] else
                              FilledButton(
                                onPressed: onContinueToSignIn,
                                child: Text(
                                  AppLocalizations.of(context)!
                                      .playbackBootstrapContinueToSignIn,
                                ),
                              ),
                            if (recoveryError != null) ...<Widget>[
                              const SizedBox(height: 12),
                              Text(
                                recoveryError!,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
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
