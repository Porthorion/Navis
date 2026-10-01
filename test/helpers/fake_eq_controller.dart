import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';

/// In-memory [EqController] for widget tests of equalizer entry points.
///
/// It records the controller calls made by the UI and applies their visible
/// effect to state, without storage or native audio.
class FakeEqController extends EqController {
  new({this.initial});

  final EqState? initial;
  final calls = <String>[];

  EqState get _value => state.requireValue;

  @override
  Future<EqState> build() async =>
      initial ??
      EqState(configuration: EqConfiguration.flat(), presets: const []);

  @override
  Future<bool> setEnabled({required bool enabled}) async {
    calls.add('enable:$enabled');
    state = AsyncData(
      _value.copyWith(
        configuration: _value.configuration.copyWith(enabled: enabled),
      ),
    );
    return true;
  }

  @override
  Future<bool> selectPreset(EqPreset preset, {bool? enable}) async {
    calls.add('select:${preset.id}:$enable');
    state = AsyncData(
      _value.copyWith(
        selectedPresetId: preset.id,
        configuration: preset.configuration.copyWith(
          enabled: enable ?? _value.configuration.enabled,
        ),
      ),
    );
    return true;
  }

  @override
  Future<bool> selectCustom() async {
    calls.add('custom');
    state = AsyncData(_value.copyWith(selectedPresetId: null));
    return true;
  }

  @override
  Future<bool> retry() async {
    calls.add('retry');
    return true;
  }

  @override
  Future<void> flushEdits() async => calls.add('flush');
}
