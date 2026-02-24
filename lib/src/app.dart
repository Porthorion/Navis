import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/theme/navis_theme.dart';

/// Root application widget for Navis.
class NavisApp extends ConsumerStatefulWidget {
  /// Creates a new [NavisApp].
  const NavisApp({super.key, this.requirePlaybackBootstrap = false});

  final bool requirePlaybackBootstrap;

  @override
  ConsumerState<NavisApp> createState() => _NavisAppState();
}

class _NavisAppState extends ConsumerState<NavisApp> {
  bool _didScheduleBootstrap = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.requirePlaybackBootstrap || _didScheduleBootstrap) {
      return;
    }
    _didScheduleBootstrap = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(audioBootstrapControllerProvider.notifier).ensureInitialized();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.requirePlaybackBootstrap) {
      final bootstrap = ref.watch(audioBootstrapControllerProvider);
      final controller = ref.read(audioBootstrapControllerProvider.notifier);
      if (bootstrap.status != AudioBootstrapStatus.ready) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          onGenerateTitle: (context) =>
              AppLocalizations.of(context)?.appName ?? 'Navis',
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.dark,
            ),
          ),
          themeMode: ThemeMode.dark,
          home: _PlaybackBootstrapGate(
            state: bootstrap,
            onRetry: controller.retry,
          ),
        );
      }
    }

    final router = ref.watch(appRouterProvider);
    final themeModeName = ref.watch(themeModeProvider);
    final colorSeed = ref.watch(colorSchemeSeedProvider);
    final seedColor = colorSeed != null ? Color(colorSeed) : Colors.blue;
    final resolvedThemeMode = resolveThemeMode(themeModeName);
    final isOled = themeModeName == 'oled';

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) =>
          AppLocalizations.of(context)?.appName ?? 'Navis',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildLightTheme(seedColor),
      darkTheme: isOled ? buildOledTheme(seedColor) : buildDarkTheme(seedColor),
      themeMode: resolvedThemeMode,
      routerConfig: router,
    );
  }
}

class _PlaybackBootstrapGate extends StatelessWidget {
  const _PlaybackBootstrapGate({
    required this.state,
    required this.onRetry,
  });

  final AudioBootstrapState state;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isFailed = state.status == AudioBootstrapStatus.failed;

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!isFailed) const CircularProgressIndicator(),
              if (!isFailed) const SizedBox(height: 16),
              Text(
                isFailed
                    ? l10n.playbackBootstrapFailedTitle
                    : l10n.playbackBootstrapLoadingTitle,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isFailed
                    ? l10n.playbackBootstrapFailedSubtitle
                    : l10n.playbackBootstrapLoadingSubtitle,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (isFailed) ...<Widget>[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: onRetry,
                  child: Text(l10n.playbackBootstrapRetryAction),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
