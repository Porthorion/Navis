import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/group_listening/presentation/listen_together_room_panel.dart';

Future<void> showListenTogetherSheet(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  final heightFactor = mediaQuery.size.width >= 840 ? 0.88 : 0.94;
  // Capture the notice controller from the caller's context so the modal can
  // surface top-pill notifications even when pushed onto the root Navigator
  // (which sits above AppNoticeScope in the widget tree).
  final noticeController = AppNoticeScope.maybeOf(context);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      Widget surface = FractionallySizedBox(
        heightFactor: heightFactor,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: const _ListenTogetherSurface(showAppBar: false),
          ),
        ),
      );
      if (noticeController != null) {
        surface = AppNoticeScope(notifier: noticeController, child: surface);
      }
      return surface;
    },
  );
}

class GroupListeningSettingsScreen extends StatelessWidget {
  const GroupListeningSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _ListenTogetherSurface(showAppBar: true);
  }
}

class _ListenTogetherSurface extends StatelessWidget {
  const _ListenTogetherSurface({required this.showAppBar});

  final bool showAppBar;

  @override
  Widget build(BuildContext context) {
    const body = ListenTogetherRoomPanel();
    if (showAppBar) {
      return Scaffold(
        appBar: AppBar(title: const Text('Listen Together')),
        body: body,
      );
    }

    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          GestureDetector(
            key: const ValueKey('groupListeningSheetHeader'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragEnd: (details) {
              if (details.primaryVelocity != null &&
                  details.primaryVelocity! > 250) {
                Navigator.of(context).maybePop();
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Column(
                children: <Widget>[
                  Container(
                    key: const ValueKey('groupListeningSheetDragHandle'),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Text(
                        'Listen Together',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Close Listen Together',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}
