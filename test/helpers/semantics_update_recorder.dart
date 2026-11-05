import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// A test binding that records every semantics update sent to the engine and
/// collects the nodes the engine's `AXTree` would reject: nodes that are
/// neither the root nor listed as a child by a node still in the tree. The
/// macOS and Windows accessibility bridges fail on such an orphan and then
/// freeze their native tree (flutter/flutter#190357, #193588).
///
/// Construct it first thing in `main()`, before any other binding is created, then read [orphans] after pumping with semantics enabled.
class SemanticsUpdateRecorderBinding
    extends AutomatedTestWidgetsFlutterBinding {
  /// One description per orphan node sent since the last [clear].
  static final List<String> orphans = <String>[];

  /// Child ids per node, merged across updates like the engine's tree.
  static final Map<int, List<int>> _children = <int, List<int>>{};

  static void clear() {
    orphans.clear();
    _children.clear();
  }

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingBuilder(super.createSemanticsUpdateBuilder());
}

class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  new(this._inner);

  final ui.SemanticsUpdateBuilder _inner;
  final Map<int, String> _described = <int, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final args = invocation.namedArguments;
    if (invocation.memberName == #updateNode) {
      final id = args[#id]! as int;
      final children = List<int>.of(
        args[#childrenInTraversalOrder]! as List<int>,
      );
      SemanticsUpdateRecorderBinding._children[id] = children;
      _described[id] =
          '#$id label="${args[#label]}" rect=${args[#rect]} '
          'traversalParent=${args[#traversalParent]} children=$children';
      return Function.apply(_inner.updateNode, const <Object?>[], args);
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(_inner.updateCustomAction, const <Object?>[], args);
    }
    return super.noSuchMethod(invocation);
  }

  @override
  ui.SemanticsUpdate build() {
    final children = SemanticsUpdateRecorderBinding._children;
    final reachable = <int>{};
    void walk(int id) {
      if (!reachable.add(id)) return;
      children[id]?.forEach(walk);
    }

    walk(0);
    for (final entry in _described.entries) {
      if (!reachable.contains(entry.key)) {
        SemanticsUpdateRecorderBinding.orphans.add(entry.value);
      }
    }
    children.removeWhere(
      (id, _) => !reachable.contains(id) && !_described.containsKey(id),
    );
    return _inner.build();
  }
}
