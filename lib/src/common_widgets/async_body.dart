import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/error_state.dart';

/// A page body for an [AsyncValue]: [data] when ready, [loading] (a centered
/// spinner by default) while it loads, and an [ErrorState] titled [errorTitle]
/// with [onRetry] when it fails.
class AsyncBody<T> extends StatelessWidget {
  const new({
    required this.value,
    required this.data,
    required this.errorTitle,
    required this.onRetry,
    this.loading = const Center(child: CircularProgressIndicator()),
    super.key,
  });

  final AsyncValue<T> value;
  final Widget Function(T value) data;
  final String errorTitle;
  final VoidCallback onRetry;
  final Widget loading;

  @override
  Widget build(BuildContext context) => value.when(
    data: data,
    loading: () => loading,
    error: (_, _) => ErrorState(title: errorTitle, onRetry: onRetry),
  );
}
