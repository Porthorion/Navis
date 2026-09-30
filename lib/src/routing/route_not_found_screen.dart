import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/routing/app_routes.dart';

/// Shown by the router for a location that no route matches, such as a stale
/// diagnostics link or a removed page.
class RouteNotFoundScreen extends StatelessWidget {
  const RouteNotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.routeNotFoundTitle)),
      body: EmptyState(
        icon: Icons.explore_off_outlined,
        title: l10n.routeNotFoundTitle,
        subtitle: l10n.routeNotFoundMessage,
        action: FilledButton(
          // The error page sits outside the shell, so replacing the location
          // is the only way back into it.
          onPressed: () => GoRouter.of(context).go(AppRoutes.home),
          child: Text(l10n.routeNotFoundGoHome),
        ),
      ),
    );
  }
}
