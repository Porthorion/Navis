import 'package:flutter/material.dart';

enum GroupListeningSessionButtonVariant { standard, filledTonal }

class GroupListeningSessionButton extends StatelessWidget {
  const GroupListeningSessionButton({
    super.key,
    this.variant = GroupListeningSessionButtonVariant.standard,
    this.constraints,
  });

  final GroupListeningSessionButtonVariant variant;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

Future<void> showListenTogetherSheet(BuildContext context) async {}
