import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/battery_optimization_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late DateTime now;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('navis_battery_tip_');
    now = DateTime.utc(2026, 10, 12, 12);
  });
  tearDown(() => directory.delete(recursive: true));

  BatteryOptimizationService service() => BatteryOptimizationService(
    now: () => now,
    supportDirectory: () async => directory,
  );

  test('dismissal persists across services until exactly 14 days', () async {
    expect(await service().isPromptSnoozed(), isFalse);
    await service().snoozePrompt();
    expect(await service().isPromptSnoozed(), isTrue);
    now = now.add(const Duration(days: 14) - const Duration(seconds: 1));
    expect(await service().isPromptSnoozed(), isTrue);
    now = now.add(const Duration(seconds: 1));
    expect(await service().isPromptSnoozed(), isFalse);
    await service().snoozePrompt();
    expect(await service().isPromptSnoozed(), isTrue);
  });

  test('invalid marker allows prompt and dismissal repairs it', () async {
    await File(p.join(directory.path, 'battery_tip_snoozed_at.txt'))
        .writeAsString('invalid');
    expect(await service().isPromptSnoozed(), isFalse);
    await service().snoozePrompt();
    expect(await service().isPromptSnoozed(), isTrue);
  });
}
