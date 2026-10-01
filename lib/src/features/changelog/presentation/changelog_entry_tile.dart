import 'package:flutter/material.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// One changelog entry as a plain paragraph. Entries sit under a heading
/// that names their type, so the row itself carries no label or marker.
class ChangelogEntryTile extends StatelessWidget {
  const ChangelogEntryTile({required this.entry, super.key});

  final ChangelogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NavisSpace.xs),
      child: Text(entry.text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
