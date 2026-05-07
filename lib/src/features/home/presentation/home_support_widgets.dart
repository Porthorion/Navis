part of 'home_screen.dart';

class _RandomHeroShimmer extends StatelessWidget {
  const _RandomHeroShimmer({
    required this.desktopMode,
    required this.adaptiveLayoutClass,
    this.density = _HomeSectionDensity.comfortable,
  });

  final bool desktopMode;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final _HomeSectionDensity density;

  double _heroHeightFor(double availableWidth) {
    final compact = density == _HomeSectionDensity.compact;
    if (desktopMode) {
      return (availableWidth * (compact ? 0.28 : 0.32)).clamp(
        compact ? 260.0 : 300.0,
        compact ? 420.0 : 500.0,
      );
    }
    return switch (adaptiveLayoutClass) {
      AdaptiveLayoutClass.phoneCompact => compact ? 208 : 228,
      AdaptiveLayoutClass.tabletMedium => compact ? 224 : 244,
      AdaptiveLayoutClass.tabletExpanded => compact ? 236 : 258,
    };
  }

  @override
  Widget build(BuildContext context) {
    final availableWidth = MediaQuery.sizeOf(context).width;
    final heroHeight = _heroHeightFor(availableWidth);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: ShimmerPlaceholder(
              height: heroHeight,
              width: double.infinity,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List<Widget>.generate(
              3,
              (index) => Padding(
                padding: EdgeInsets.only(right: index == 2 ? 0 : 6),
                child: ShimmerPlaceholder(
                  height: 6,
                  width: index == 1 ? 16 : 6,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CarouselShimmer extends StatelessWidget {
  const _CarouselShimmer({
    required this.compactWideLandscapeMode,
    this.density = _HomeSectionDensity.comfortable,
  });

  final bool compactWideLandscapeMode;
  final _HomeSectionDensity density;

  @override
  Widget build(BuildContext context) {
    final compactDensity = density == _HomeSectionDensity.compact;
    final cardSize = compactDensity ? 138.0 : 150.0;
    return SizedBox(
      height: cardSize,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: compactWideLandscapeMode ? 0 : 16,
        ),
        itemCount: 4,
        separatorBuilder: (_, _) => SizedBox(width: compactDensity ? 10 : 12),
        itemBuilder: (context, _) {
          return SizedBox(
            width: cardSize,
            child: Card(
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ShimmerPlaceholder(
                height: cardSize,
                width: cardSize,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ListShimmer extends StatelessWidget {
  const _ListShimmer({
    this.density = _HomeSectionDensity.comfortable,
  });

  final _HomeSectionDensity density;

  @override
  Widget build(BuildContext context) {
    final compactDensity = density == _HomeSectionDensity.compact;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: List<Widget>.generate(
          4,
          (index) => Padding(
            padding: EdgeInsets.only(bottom: index == 3 ? 0 : 8),
            child: ShimmerPlaceholder(
              height: compactDensity ? 52 : 60,
              width: double.infinity,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updateAsync = ref.watch(updateProvider);
    final settings = ref.watch(appSettingsProvider).asData?.value;

    if (settings != null && !settings.updateCheckEnabled) {
      return const SizedBox.shrink();
    }

    return updateAsync.when(
      data: (info) {
        if (info == null) return const SizedBox.shrink();
        return MaterialBanner(
          content: Text(l10n.updateAvailableBody(info.tagName)),
          leading: const Icon(Icons.system_update_outlined),
          actions: [
            TextButton(
              onPressed: () => ref.invalidate(updateProvider),
              child: Text(l10n.updateDismiss),
            ),
            TextButton(
              onPressed: () {
                if (info.downloadUrl != null) {
                  showUpdateDialog(context, info);
                } else {
                  launchUrl(
                    Uri.parse(info.htmlUrl),
                    mode: LaunchMode.externalApplication,
                  );
                }
              },
              child: Text(
                info.downloadUrl != null
                    ? l10n.updateInstall
                    : l10n.updateDownload,
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}
