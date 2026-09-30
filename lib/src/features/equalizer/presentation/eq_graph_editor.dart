import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_response.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_geometry.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_painter.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// A graph of authored bands with independent, explicitly labelled output gain.
class EqGraphEditor extends StatefulWidget {
  const EqGraphEditor({
    required this.configuration,
    required this.selectedBand,
    required this.onSelect,
    required this.onBegin,
    required this.onChanged,
    required this.onCommit,
    required this.onCancel,
    required this.onPreampInput,
    this.sampleRate = 48000,
    this.compact = false,
    this.enabled = true,
    this.readOnly = false,
    this.readOnlyMinimumLimit = 24,
    super.key,
  });
  final EqConfiguration configuration;
  final int? selectedBand;
  final ValueChanged<int> onSelect;
  final VoidCallback onBegin;
  final ValueChanged<EqConfiguration> onChanged;
  final VoidCallback onCommit;
  final VoidCallback onCancel;
  final VoidCallback onPreampInput;

  /// Smallest ± dB range a read-only graph fits to.
  final double readOnlyMinimumLimit;
  final double sampleRate;

  /// A compact preview omits the toolbar; the page then offers preamp elsewhere.
  final bool compact;
  final bool enabled;
  final bool readOnly;

  @override
  State<EqGraphEditor> createState() => EqGraphEditorState();
}

class EqGraphEditorState extends State<EqGraphEditor> {
  double _limit = 24;
  bool _output = false;
  late EqGraphSamples _samples;
  final _focus = FocusNode(debugLabel: 'eq-graph');
  bool _focused = false;
  EqConfiguration? _dragStart;
  EqGraphGeometry? _dragGeometry;
  Offset? _down;
  int? _dragBand;
  double _preampStart = 0;
  double _preampDistance = 0;
  Timer? _wheelTimer;
  EqConfiguration? _wheelStart;
  int? _wheelBand;
  Timer? _headroomTimer;
  bool _calculating = false;
  int _responseRevision = 0;
  int _completedRevision = -1;
  double _headroom = 0;
  bool _calculationRunning = false;

  @override
  void initState() {
    super.initState();
    _sample();
  }

  @override
  void didUpdateWidget(EqGraphEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configuration != widget.configuration ||
        oldWidget.sampleRate != widget.sampleRate ||
        oldWidget.selectedBand != widget.selectedBand) {
      _sample();
    }
  }

  void _sample() {
    _samples = EqGraphSamples(
      widget.configuration,
      widget.sampleRate,
      widget.selectedBand,
    );
    _responseRevision++;
    if (widget.readOnly) {
      _limit = _samples.fittedLimitAtLeast(widget.readOnlyMinimumLimit);
    }
    if (_output) _scheduleHeadroom();
  }

  void _scheduleHeadroom() {
    _calculating = true;
    _headroomTimer?.cancel();
    _headroomTimer = Timer(
      const Duration(milliseconds: 120),
      _calculateHeadroom,
    );
  }

  /// Reveals effective output when entering the exact preamp control.
  void revealOutputResponse() {
    if (_output) return;
    setState(() => _output = true);
    _scheduleHeadroom();
  }

  Future<void> _calculateHeadroom() async {
    if (_calculationRunning || !mounted) return;
    _calculationRunning = true;
    final revision = _responseRevision;
    final values = widget.configuration;
    final rate = widget.sampleRate;
    final value = await compute(_calculateOutputGain, (values, rate));
    _calculationRunning = false;
    if (!mounted) return;
    if (revision == _responseRevision) {
      setState(() {
        _headroom = value;
        _completedRevision = revision;
        _calculating = false;
      });
    } else if (_output) {
      _scheduleHeadroom();
    }
  }

  @override
  void dispose() {
    _headroomTimer?.cancel();
    _wheelTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  /// Diagnostics uses the same edit callbacks as a pointer gesture.
  void dragBand(int index, double dx, double dy, {bool cancel = false}) {
    if (!widget.enabled || index >= widget.configuration.filters.length) return;
    final geometry = EqGraphGeometry(
      const Rect.fromLTWH(0, 0, 600, 300),
      limit: _limit,
    );
    final current = widget.configuration;
    widget.onSelect(index);
    widget.onBegin();
    final filters = [...current.filters];
    filters[index] = geometry.drag(
      filters[index],
      geometry.handle(filters[index]),
      Offset(dx, dy),
      current.mode,
    );
    widget.onChanged(current.copyWith(filters: filters));
    if (cancel) {
      widget.onCancel();
    } else {
      widget.onCommit();
    }
  }

  /// Measures real rendered frames while exercising one continuous graph edit.
  Future<Map<String, Object>> profileDrag(int index, {int steps = 180}) async {
    if (!widget.enabled || index >= widget.configuration.filters.length) {
      throw StateError('Select an editable band before profiling.');
    }
    final before = widget.configuration;
    final timings = <FrameTiming>[];
    void capture(List<FrameTiming> frames) => timings.addAll(frames);
    final stopwatch = Stopwatch()..start();
    SchedulerBinding.instance.addTimingsCallback(capture);
    widget.onSelect(index);
    widget.onBegin();
    setState(() => _dragBand = index);
    try {
      for (var i = 1; i <= steps; i++) {
        if (!mounted || !widget.enabled) break;
        final filters = [...before.filters];
        filters[index] = filters[index].copyWith(
          gainDb: (filters[index].gainDb + math.sin(i / 12) * 2).clamp(-24, 24),
        );
        widget.onChanged(before.copyWith(filters: filters));
        await WidgetsBinding.instance.endOfFrame;
      }
      widget.onCancel();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } finally {
      SchedulerBinding.instance.removeTimingsCallback(capture);
      if (mounted) setState(() => _dragBand = null);
    }
    double percentile(List<double> values) {
      if (values.isEmpty) return 0;
      values.sort();
      return values[((values.length - 1) * .95).ceil()];
    }

    return {
      'steps': steps,
      'bands': before.filters.length,
      'frames': timings.length,
      'elapsedMs': stopwatch.elapsedMilliseconds,
      'buildP95Ms': percentile(
        timings.map((f) => f.buildDuration.inMicroseconds / 1000).toList(),
      ),
      'rasterP95Ms': percentile(
        timings.map((f) => f.rasterDuration.inMicroseconds / 1000).toList(),
      ),
    };
  }

  void _step(int index, {double gain = 0, double octaves = 0}) {
    if (!widget.enabled) return;
    _endWheel();
    final current = widget.configuration;
    final filters = [...current.filters];
    final band = filters[index];
    filters[index] = band.copyWith(
      gainDb: band.usesGain ? (band.gainDb + gain).clamp(-24, 24) : band.gainDb,
      frequencyHz: current.mode == EqMode.advanced && octaves != 0
          ? (band.frequencyHz * math.pow(2, octaves)).clamp(20, 20000)
          : band.frequencyHz,
    );
    widget.onBegin();
    widget.onChanged(current.copyWith(filters: filters));
    widget.onCommit();
  }

  void _stepPreamp(double db) {
    if (!widget.enabled) return;
    final current = widget.configuration;
    revealOutputResponse();
    widget.onBegin();
    widget.onChanged(
      current.copyWith(preampDb: (current.preampDb + db).clamp(-60, 24)),
    );
    widget.onCommit();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final index = widget.selectedBand;
    if (!widget.enabled ||
        index == null ||
        index >= widget.configuration.filters.length ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final fine = HardwareKeyboard.instance.isShiftPressed;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _step(index, gain: fine ? .01 : .1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _step(index, gain: fine ? -.01 : -.1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _step(index, octaves: fine ? -.001 : -.01);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _step(index, octaves: fine ? .001 : .01);
    } else if (event.logicalKey == LogicalKeyboardKey.escape &&
        _dragStart != null) {
      _cancel();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _choose(List<int> hits) async {
    if (hits.isEmpty || !widget.enabled) return;
    _focus.requestFocus();
    if (hits.length == 1) {
      widget.onSelect(hits.single);
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final identity = widget.configuration;
    final selected = widget.selectedBand;
    final index = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.eqChooseBand),
        children: [
          for (final i in hits)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: Row(
                children: [
                  Icon(
                    i == selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${l10n.eqBand(i + 1)} · ${eqNumber(identity.filters[i].frequencyHz)} Hz',
                        ),
                        Text(
                          eqBandSummary(l10n, identity.filters[i]),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (mounted && identity == widget.configuration && index != null) {
      widget.onSelect(index);
    }
  }

  void _cancel() {
    if (_dragStart != null) widget.onCancel();
    _dragStart = null;
    _dragGeometry = null;
    if (_dragBand != null) setState(() => _dragBand = null);
  }

  /// Mouse-wheel Q adjustments form one Undo step once the wheel rests.
  void _wheel(PointerSignalEvent event, EqGraphGeometry geometry) {
    if (event is! PointerScrollEvent ||
        !widget.enabled ||
        _dragStart != null ||
        widget.configuration.mode != EqMode.advanced) {
      return;
    }
    final targets = geometry.target(
      widget.configuration.filters,
      event.localPosition,
      selected: widget.selectedBand,
    );
    final index = _wheelBand ?? (targets.length == 1 ? targets.single : null);
    if (index == null) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (signal) {
      final scroll = (signal as PointerScrollEvent).scrollDelta.dy;
      if (scroll == 0 || !mounted || !widget.enabled) return;
      if (_wheelBand == null) {
        if (widget.selectedBand != index) widget.onSelect(index);
        final start = widget.configuration;
        widget.onBegin();
        _wheelBand = index;
        _wheelStart = start;
      }
      final current = widget.configuration;
      final band = current.filters[index];
      final fine = HardwareKeyboard.instance.isShiftPressed ? .1 : 1.0;
      final filters = [...current.filters];
      filters[index] = band.copyWith(
        q: EqGraphGeometry.qAt(
          EqGraphGeometry.qPosition(band.q) - scroll / 2000 * fine,
        ),
      );
      widget.onChanged(current.copyWith(filters: filters));
      _wheelTimer?.cancel();
      _wheelTimer = Timer(const Duration(milliseconds: 450), _endWheel);
    });
  }

  /// Commits a resting wheel session before another edit starts, so its
  /// delayed commit can never end the newer session.
  void settleWheel() => _endWheel();

  void _endWheel() {
    _wheelTimer?.cancel();
    _wheelTimer = null;
    if (_wheelBand == null) return;
    final changed = _wheelStart != widget.configuration;
    _wheelBand = null;
    _wheelStart = null;
    if (changed) {
      widget.onCommit();
    } else {
      widget.onCancel();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildGraph(context, constraints.maxHeight, constraints.maxWidth),
  );

  Widget _buildGraph(BuildContext context, double height, double width) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final current = widget.configuration;
    final toolbar = !widget.readOnly && !widget.compact && height >= 150;
    final summary = _output && !widget.readOnly && height >= 120;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      canRequestFocus: !widget.readOnly,
      onFocusChange: (value) => setState(() => _focused = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: NavisRadius.lgAll,
          border: Border.all(
            color: _focused && widget.enabled && !widget.readOnly
                ? colors.primary
                : colors.outlineVariant.withValues(alpha: .6),
            width: _focused && widget.enabled && !widget.readOnly ? 2 : 1,
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          6,
          toolbar ? 4 : 8,
          6,
          summary ? 4 : 6,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (toolbar) _toolbar(context, l10n, width),
            Expanded(child: _plot(context, l10n, current)),
            if (summary)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                child: Text(
                  '${l10n.eqOutputResponse}: ${_calculating ? l10n.eqCalculatingOutput : '${l10n.eqAttenuation}: ${eqNumber(_headroom)} dB · ${l10n.eqEffectiveOutput}: ${eqNumber(current.preampDb + _headroom)} dB'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context, AppLocalizations l10n, double width) {
    final roomy = width >= 560;
    final canFit = _samples.maximum > 24 || _limit > 24;
    final fitted = _limit > 24;
    void fit() => setState(
      () => _limit = fitted ? 24 : _samples.fittedLimit,
    );
    void output() => setState(() {
      _output = !_output;
      if (_output) _scheduleHeadroom();
    });
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: _preamp(context, l10n, roomy: roomy),
          ),
        ),
        if (roomy) ...[
          TextButton.icon(
            key: const ValueKey('eq-fit-response'),
            onPressed: canFit && _dragStart == null ? fit : null,
            icon: Icon(fitted ? Icons.fit_screen : Icons.fit_screen_outlined),
            label: Text(l10n.eqFitResponse),
          ),
          FilterChip(
            key: const ValueKey('eq-output-response'),
            label: Text(l10n.eqOutputResponse),
            selected: _output,
            onSelected: (_) => output(),
          ),
        ] else ...[
          IconButton(
            key: const ValueKey('eq-fit-response'),
            tooltip: l10n.eqFitResponse,
            isSelected: fitted,
            onPressed: canFit && _dragStart == null ? fit : null,
            icon: const Icon(Icons.fit_screen_outlined),
            selectedIcon: const Icon(Icons.fit_screen),
          ),
          IconButton(
            key: const ValueKey('eq-output-response'),
            tooltip: l10n.eqOutputResponse,
            isSelected: _output,
            onPressed: output,
            icon: const Icon(Icons.stacked_line_chart),
          ),
        ],
      ],
    );
  }

  /// The only preamp control while the toolbar is visible.
  Widget _preamp(
    BuildContext context,
    AppLocalizations l10n, {
    required bool roomy,
  }) {
    final current = widget.configuration;
    final value = '${eqSignedGain(current.preampDb)} dB';
    final button = TextButton.icon(
      key: const ValueKey('eq-input-preamp'),
      onPressed: widget.enabled ? widget.onPreampInput : null,
      icon: Icon(roomy ? Icons.edit_outlined : Icons.unfold_more, size: 18),
      label: Text(
        '${l10n.eqPreamp} $value',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    if (roomy) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: button),
          SizedBox(
            width: 150,
            child: Listener(
              onPointerCancel: widget.enabled ? (_) => widget.onCancel() : null,
              child: Slider(
                key: const ValueKey('eq-graph-preamp'),
                value: current.preampDb,
                min: -60,
                max: 24,
                semanticFormatterCallback: (value) =>
                    '${l10n.eqPreamp} ${eqNumber(value)} dB',
                onChangeStart: widget.enabled
                    ? (_) {
                        revealOutputResponse();
                        widget.onBegin();
                      }
                    : null,
                onChanged: widget.enabled
                    ? (value) => widget.onChanged(
                        widget.configuration.copyWith(preampDb: value),
                      )
                    : null,
                onChangeEnd: widget.enabled ? (_) => widget.onCommit() : null,
              ),
            ),
          ),
        ],
      );
    }
    return Semantics(
      label: l10n.eqPreamp,
      value: value,
      hint: l10n.eqPreampDrag,
      increasedValue:
          '${eqSignedGain((current.preampDb + .5).clamp(-60, 24))} dB',
      decreasedValue:
          '${eqSignedGain((current.preampDb - .5).clamp(-60, 24))} dB',
      onIncrease: widget.enabled ? () => _stepPreamp(.5) : null,
      onDecrease: widget.enabled ? () => _stepPreamp(-.5) : null,
      child: GestureDetector(
        key: const ValueKey('eq-graph-preamp'),
        onVerticalDragStart: widget.enabled
            ? (_) {
                _preampStart = current.preampDb;
                _preampDistance = 0;
                revealOutputResponse();
                widget.onBegin();
              }
            : null,
        onVerticalDragUpdate: widget.enabled
            ? (details) {
                _preampDistance += details.delta.dy;
                widget.onChanged(
                  widget.configuration.copyWith(
                    preampDb: (_preampStart - _preampDistance * .15).clamp(
                      -60,
                      24,
                    ),
                  ),
                );
              }
            : null,
        onVerticalDragEnd: widget.enabled ? (_) => widget.onCommit() : null,
        onVerticalDragCancel: widget.enabled ? widget.onCancel : null,
        child: Tooltip(message: l10n.eqPreampDrag, child: button),
      ),
    );
  }

  Widget _plot(
    BuildContext context,
    AppLocalizations l10n,
    EqConfiguration current,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final geometry = EqGraphGeometry.inside(size, limit: _limit);
      final interactive = widget.enabled && !widget.readOnly;
      return Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: Listener(
                onPointerSignal: interactive
                    ? (event) => _wheel(event, geometry)
                    : null,
                child: GestureDetector(
                  key: const ValueKey('eq-graph-plot'),
                  behavior: HitTestBehavior.opaque,
                  onPanDown: interactive
                      ? (details) => _down = details.localPosition
                      : null,
                  onTapUp: interactive
                      ? (details) => unawaited(
                          _choose(
                            geometry.target(
                              current.filters,
                              details.localPosition,
                            ),
                          ),
                        )
                      : null,
                  onPanStart: interactive
                      ? (details) {
                          _endWheel();
                          final pointer = _down ?? details.localPosition;
                          final targets = geometry.target(
                            current.filters,
                            pointer,
                            selected: widget.selectedBand,
                          );
                          if (targets.length != 1) {
                            unawaited(_choose(targets));
                            return;
                          }
                          final index = targets.single;
                          _focus.requestFocus();
                          widget.onSelect(index);
                          _dragStart = current;
                          _dragGeometry = geometry;
                          setState(() => _dragBand = index);
                          widget.onBegin();
                        }
                      : null,
                  onPanUpdate: interactive
                      ? (details) {
                          if (_dragStart == null || _dragBand == null) {
                            return;
                          }
                          final start = _dragStart!;
                          final band = start.filters[_dragBand!];
                          final fine = HardwareKeyboard.instance.isShiftPressed
                              ? .1
                              : 1.0;
                          final filters = [...start.filters];
                          filters[_dragBand!] = _dragGeometry!.drag(
                            band,
                            _dragGeometry!.handle(band),
                            (details.localPosition - _down!) * fine,
                            start.mode,
                          );
                          widget.onChanged(start.copyWith(filters: filters));
                        }
                      : null,
                  onPanEnd: interactive
                      ? (_) {
                          if (_dragStart != null) widget.onCommit();
                          _dragStart = null;
                          _dragGeometry = null;
                          setState(() => _dragBand = null);
                        }
                      : null,
                  onPanCancel: _cancel,
                  child: CustomPaint(
                    painter: EqGraphPainter(
                      samples: _samples,
                      configuration: current,
                      geometry: geometry,
                      colors: Theme.of(context).colorScheme,
                      selected: widget.selectedBand,
                      textScaler: MediaQuery.textScalerOf(
                        context,
                      ).clamp(maxScaleFactor: 1.4),
                      labelStyle:
                          Theme.of(context).textTheme.labelSmall ??
                          const TextStyle(),
                      outputOffset:
                          _output && _completedRevision == _responseRevision
                          ? current.preampDb + _headroom
                          : null,
                      dragging: _dragBand != null,
                      readOnly: widget.readOnly,
                      filterLabel: l10n.eqFilterResponse,
                      outputLabel: l10n.eqOutputResponse,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (!widget.readOnly)
            for (var i = 0; i < current.filters.length; i++)
              _handleSemantics(l10n, geometry, size, current, i),
        ],
      );
    },
  );

  Widget _handleSemantics(
    AppLocalizations l10n,
    EqGraphGeometry geometry,
    Size size,
    EqConfiguration current,
    int i,
  ) {
    final filter = current.filters[i];
    final point = geometry.handle(filter);
    String describe(double gain) => [
      if (filter.usesGain) '${eqNumber(gain)} dB',
      'Q ${eqNumber(filter.q, decimals: 3)}',
      if (!filter.enabled) l10n.eqBandOff,
    ].join(', ');
    return Positioned(
      left: (point.dx - 24).clamp(0, math.max(0, size.width - 48)),
      top: (point.dy - 24).clamp(0, math.max(0, size.height - 48)),
      child: IgnorePointer(
        child: Semantics(
          label: '${l10n.eqBand(i + 1)}, ${eqNumber(filter.frequencyHz)} Hz',
          value: describe(filter.gainDb),
          increasedValue: describe((filter.gainDb + .1).clamp(-24, 24)),
          decreasedValue: describe((filter.gainDb - .1).clamp(-24, 24)),
          selected: widget.selectedBand == i,
          enabled: widget.enabled,
          onTap: widget.enabled ? () => widget.onSelect(i) : null,
          onIncrease: widget.enabled && filter.usesGain
              ? () => _step(i, gain: .1)
              : null,
          onDecrease: widget.enabled && filter.usesGain
              ? () => _step(i, gain: -.1)
              : null,
          child: const SizedBox(width: 48, height: 48),
        ),
      ),
    );
  }
}

/// Filter type, gain and Q in one line for choosers and previews.
String eqBandSummary(AppLocalizations l10n, EqFilter filter) => [
  eqFilterTypeLabel(l10n, filter.type),
  if (filter.usesGain) '${eqSignedGain(filter.gainDb)} dB',
  'Q ${eqNumber(filter.q, decimals: 3)}',
  if (!filter.enabled) l10n.eqBandOff,
].join(' · ');

String eqFilterTypeLabel(AppLocalizations l10n, EqFilterType type) =>
    switch (type) {
      EqFilterType.peaking => l10n.eqPeaking,
      EqFilterType.lowShelf => l10n.eqLowShelf,
      EqFilterType.highShelf => l10n.eqHighShelf,
      EqFilterType.lowPass => l10n.eqLowPass,
      EqFilterType.highPass => l10n.eqHighPass,
      EqFilterType.notch => l10n.eqNotch,
    };

double _calculateOutputGain((EqConfiguration, double) input) {
  final (configuration, sampleRate) = input;
  return configuration.supportsSampleRate(sampleRate)
      ? EqResponse(configuration, sampleRate: sampleRate).headroomDb
      : 0;
}
