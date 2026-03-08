import 'package:flutter/material.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/desktop_tokens.dart';

class DesktopFrame extends StatelessWidget {
  const DesktopFrame({
    required this.layoutClass,
    required this.child,
    super.key,
    this.padding = const EdgeInsets.fromLTRB(20, 20, 20, 20),
  });

  final DesktopLayoutClass layoutClass;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = desktopTokensOf(context);
    final maxWidth = switch (layoutClass) {
      DesktopLayoutClass.compactDesktop => tokens.frameMaxWidthCompact,
      DesktopLayoutClass.standardDesktop => tokens.frameMaxWidthStandard,
      DesktopLayoutClass.ultraWideDesktop => tokens.frameMaxWidthUltraWide,
    };
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class DesktopPanel extends StatelessWidget {
  const DesktopPanel({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tokens = desktopTokensOf(context);
    return Material(
      color: color ?? colors.surfaceContainerLow,
      elevation: tokens.panelElevation,
      borderRadius: BorderRadius.circular(tokens.panelRadius),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}

class DesktopSectionHeader extends StatelessWidget {
  const DesktopSectionHeader({
    required this.title,
    super.key,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.only(bottom: 10),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null && subtitle!.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class DesktopListRow extends StatelessWidget {
  const DesktopListRow({
    required this.title,
    super.key,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onSecondaryTapDown,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tokens = desktopTokensOf(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        mouseCursor: onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        hoverColor: colors.onSurface.withValues(alpha: tokens.hoverOpacity),
        highlightColor: colors.onSurface.withValues(alpha: tokens.hoverOpacity),
        splashColor: colors.onSurface.withValues(
          alpha: tokens.hoverOpacity * 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DesktopCard extends StatelessWidget {
  const DesktopCard({
    required this.child,
    super.key,
    this.onTap,
    this.padding = const EdgeInsets.all(12),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tokens = desktopTokensOf(context);
    return Material(
      color: colors.surfaceContainer,
      borderRadius: BorderRadius.circular(tokens.cardRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class DesktopEmptyState extends StatelessWidget {
  const DesktopEmptyState({
    required this.title,
    super.key,
    this.subtitle,
    this.icon = Icons.hourglass_empty,
    this.action,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 42, color: colors.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null && subtitle!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    subtitle!,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              if (action != null) ...<Widget>[
                const SizedBox(height: 14),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
