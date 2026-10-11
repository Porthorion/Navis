import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common/preset_names.dart';

void main() {
  const presets = [(id: '1', name: 'Evening'), (id: '2', name: 'Morning')];
  PresetFailure? validate(String name, {String? excludingId}) =>
      validatePresetName(
        name,
        presets: presets,
        excludingId: excludingId,
        reservedNames: const {'default'},
      );
  test('trims, requires a name, reserves built-ins, ignores case', () {
    expect(validate('  '), PresetFailure.emptyName);
    expect(validate(' DEFAULT '), PresetFailure.reservedName);
    expect(validate(' evening '), PresetFailure.duplicateName);
    expect(validate('evening', excludingId: '1'), isNull);
    expect(validate('morning', excludingId: '1'), PresetFailure.duplicateName);
    expect(validate('New name'), isNull);
  });
}
