import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';

class ExternalSourceBadge extends StatelessWidget {
  const ExternalSourceBadge({required this.size, super.key});

  static const semanticsKey = ValueKey<String>('external-source-badge');

  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final label = AppLocalizations.of(context)!.externalSourceBadgeLabel;
    return Tooltip(
      message: label,
      child: Semantics(
        key: semanticsKey,
        label: label,
        child: IgnorePointer(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.surface.withValues(alpha: 0.94),
              border: Border.all(
                color: colorScheme.onSurface.withValues(alpha: 0.22),
              ),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.cloud_outlined,
              size: size == 18 ? 11 : 15,
              color: colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
