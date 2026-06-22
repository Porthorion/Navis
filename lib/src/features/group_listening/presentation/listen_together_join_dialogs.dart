import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

final RegExp listenTogetherInviteCodePattern = RegExp(r'^[A-Za-z0-9_-]{24}$');
final RegExp listenTogetherPinPattern = RegExp(r'^\d{4}$');

Future<String?> readListenTogetherClipboardInviteCode() async {
  final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
  final text = clipboard?.text?.trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  for (final token in text.split(RegExp('[\\s"\'<>]+'))) {
    final trimmed = token.trim();
    if (listenTogetherInviteCodePattern.hasMatch(trimmed)) {
      return trimmed;
    }
  }
  return null;
}

Future<String?> showListenTogetherRoomPinDialog(
  BuildContext context, {
  GroupListeningErrorState? failure,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) {
      String? errorText = switch (failure?.code) {
        GroupListeningErrorCode.pinInvalid => 'That PIN did not work.',
        _ => null,
      };
      return StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final pin = controller.text.trim();
            if (!listenTogetherPinPattern.hasMatch(pin)) {
              setDialogState(() {
                errorText = 'Enter 4 digits.';
              });
              return;
            }
            Navigator.of(context).pop(pin);
          }

          return AlertDialog(
            icon: const Icon(Icons.lock_outline),
            title: const Text('Room PIN'),
            content: TextField(
              key: const ValueKey('groupListeningAvailableRoomPinField'),
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              obscureText: true,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: InputDecoration(
                labelText: 'Room PIN',
                hintText: '4 digits',
                errorText: errorText,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
              ),
              onChanged: (_) {
                if (errorText != null) {
                  setDialogState(() {
                    errorText = null;
                  });
                }
              },
              onSubmitted: (_) => submit(),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                key: const ValueKey(
                  'groupListeningAvailableRoomPinConfirmButton',
                ),
                onPressed: submit,
                icon: const Icon(Icons.login_outlined),
                label: const Text('Join room'),
              ),
            ],
          );
        },
      );
    },
  );
}

class ListenTogetherJoinWithCodeDialog extends StatefulWidget {
  const ListenTogetherJoinWithCodeDialog({
    required this.initialInviteCode,
    required this.pinFailure,
    required this.showClipboardHint,
    super.key,
  });

  final String? initialInviteCode;
  final GroupListeningErrorState? pinFailure;
  final bool showClipboardHint;

  @override
  State<ListenTogetherJoinWithCodeDialog> createState() =>
      _ListenTogetherJoinWithCodeDialogState();
}

class _ListenTogetherJoinWithCodeDialogState
    extends State<ListenTogetherJoinWithCodeDialog> {
  late final TextEditingController _inviteController;
  late final TextEditingController _pinController;
  String? _inviteErrorText;
  String? _pinErrorText;

  @override
  void initState() {
    super.initState();
    _inviteController = TextEditingController(text: widget.initialInviteCode);
    _pinController = TextEditingController();
    _pinErrorText = switch (widget.pinFailure?.code) {
      GroupListeningErrorCode.pinRequired => 'Enter this room PIN.',
      GroupListeningErrorCode.pinInvalid => 'That PIN did not work.',
      _ => null,
    };
  }

  @override
  void dispose() {
    _inviteController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  void _submit() {
    final normalized = _inviteController.text.trim();
    if (normalized.isEmpty) {
      setState(() {
        _inviteErrorText = 'Enter an invite code to join a room.';
      });
      return;
    }

    final normalizedPin = _pinController.text.trim();
    if (normalizedPin.isNotEmpty &&
        !listenTogetherPinPattern.hasMatch(normalizedPin)) {
      setState(() {
        _pinErrorText = 'Enter 4 digits.';
      });
      return;
    }

    Navigator.of(context).pop(
      (
        inviteCode: normalized,
        pinCode: normalizedPin.isEmpty ? null : normalizedPin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.pin_outlined),
      title: const Text('Code Join'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: const ValueKey('groupListeningJoinWithCodeField'),
            controller: _inviteController,
            autofocus: widget.pinFailure == null,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: TextInputType.text,
            decoration: InputDecoration(
              labelText: 'Invite code',
              hintText: 'Paste a Voyage invite',
              errorText: _inviteErrorText,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.meeting_room_outlined),
            ),
            onChanged: (_) {
              if (_inviteErrorText != null) {
                setState(() {
                  _inviteErrorText = null;
                });
              }
            },
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('groupListeningJoinWithCodePinField'),
            controller: _pinController,
            autofocus: widget.pinFailure != null,
            keyboardType: TextInputType.number,
            obscureText: true,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: InputDecoration(
              labelText: 'Room PIN',
              hintText: '4 digits',
              errorText: _pinErrorText,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock_outline),
            ),
            onChanged: (_) {
              if (_pinErrorText != null) {
                setState(() {
                  _pinErrorText = null;
                });
              }
            },
            onSubmitted: (_) => _submit(),
          ),
          if (widget.showClipboardHint) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'Detected an invite code from your clipboard.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey('groupListeningJoinWithCodeCancelButton'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const ValueKey('groupListeningJoinWithCodeConfirmButton'),
          onPressed: _submit,
          icon: const Icon(Icons.login_outlined),
          label: const Text('Join room'),
        ),
      ],
    );
  }
}
