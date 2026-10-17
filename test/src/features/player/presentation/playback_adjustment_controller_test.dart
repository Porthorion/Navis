import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _Repository extends Mock implements SettingsRepository;

class _Handler extends Mock implements NavisPlaybackHandler;

void main() {
  setUpAll(() => registerFallbackValue(const PlaybackAdjustments()));
  late _Repository repository;
  late _Handler handler;
  late ProviderContainer container;
  late PlaybackAdjustmentController controller;
  late List<PlaybackAdjustments> saved;
  late List<PlaybackAdjustments> applied;

  setUp(() async {
    repository = _Repository();
    handler = _Handler();
    saved = [];
    applied = [];
    when(() => handler.playbackAdjustmentsStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => handler.playbackAdjustments)
        .thenAnswer((_) => applied.lastOrNull ?? const PlaybackAdjustments());
    when(() => handler.playbackAdjustmentCapabilities)
        .thenReturn(PlaybackAdjustmentCapabilities.android);
    when(() => handler.setPlaybackAdjustments(any())).thenAnswer((i) async {
      applied.add(i.positionalArguments.first as PlaybackAdjustments);
    });
    when(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    ).thenAnswer((i) async {
      saved.add(i.namedArguments[#values] as PlaybackAdjustments);
    });
    container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        settingsRepositoryProvider.overrideWithValue(repository),
        audioHandlerProvider.overrideWithValue(handler),
      ],
    );
    controller = container.read(playbackAdjustmentsProvider.notifier);
    await container.read(playbackAdjustmentsProvider.future);
  });
  tearDown(() => container.dispose());

  test('lock, presets, and None retain exact mode and unlock sound', () async {
    await controller.setValues(const PlaybackAdjustments(speed: 1.25));
    expect(await controller.setPitchLock(enabled: true), isTrue);
    final linked = container
        .read(playbackAdjustmentsProvider)
        .requireValue
        .values;
    expect(linked.pitchFactor, 1.25);
    await controller.savePreset('Linked');
    final id = container
        .read(playbackAdjustmentsProvider)
        .requireValue
        .selectedPresetId!;
    await controller.setPitchLock(enabled: false);
    expect(applied.last.pitchSemitones, linked.pitchSemitones);
    await controller.setValues(applied.last.copyWith(speed: 1.5));
    expect(applied.last.pitchFactor, closeTo(1.25, 1e-14));
    await controller.selectPreset(id);
    expect(applied.last.lockPitchToSpeed, isTrue);
    expect(saved.last, linked);
    await controller.selectPreset('none');
    expect(saved.last.isNone, isTrue);
  });
  test('confirmed outside changes persist without replaying setters', () async {
    final events = StreamController<PlaybackAdjustments>();
    addTearDown(events.close);
    when(() => handler.playbackAdjustmentsStream)
        .thenAnswer((_) => events.stream);
    container.invalidate(playbackAdjustmentsProvider);
    await container.read(playbackAdjustmentsProvider.future);
    const direct = PlaybackAdjustments(speed: 0.99, lockPitchToSpeed: true);
    when(() => handler.playbackAdjustments).thenReturn(direct);
    events.add(direct);
    await Future<void>.delayed(Duration.zero);
    await controller.flush();
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.values,
      direct,
    );
    expect(saved.last, direct);
    verifyNever(() => handler.setPlaybackAdjustments(any()));
  });
  test('replacing the engine detaches old confirmations immediately', () async {
    final oldEvents = StreamController<PlaybackAdjustments>();
    final newEvents = StreamController<PlaybackAdjustments>();
    addTearDown(oldEvents.close);
    addTearDown(newEvents.close);
    when(() => handler.playbackAdjustmentsStream)
        .thenAnswer((_) => oldEvents.stream);
    final replacement = _Handler();
    when(() => replacement.playbackAdjustments)
        .thenReturn(const PlaybackAdjustments());
    when(() => replacement.playbackAdjustmentsStream)
        .thenAnswer((_) => newEvents.stream);
    when(() => replacement.playbackAdjustmentCapabilities)
        .thenReturn(PlaybackAdjustmentCapabilities.android);
    final restored = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        settingsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(restored.dispose);
    await restored.read(audioHandlerStateProvider.notifier).setHandler(handler);
    await restored.read(playbackAdjustmentsProvider.future);
    await restored
        .read(audioHandlerStateProvider.notifier)
        .setHandler(replacement);
    oldEvents.add(const PlaybackAdjustments(speed: 1.5));
    await Future<void>.delayed(Duration.zero);
    expect(oldEvents.hasListener, isFalse);
    expect(
      restored.read(playbackAdjustmentsProvider).requireValue.values.isNone,
      isTrue,
    );
    const latest = PlaybackAdjustments(speed: 1.25, lockPitchToSpeed: true);
    newEvents.add(latest);
    await Future<void>.delayed(Duration.zero);
    expect(
      restored.read(playbackAdjustmentsProvider).requireValue.values,
      latest,
    );
  });
  test('old confirmations never overwrite a newer pending preview', () async {
    final events = StreamController<PlaybackAdjustments>();
    addTearDown(events.close);
    when(() => handler.playbackAdjustmentsStream)
        .thenAnswer((_) => events.stream);
    container.invalidate(playbackAdjustmentsProvider);
    await container.read(playbackAdjustmentsProvider.future);
    final gate = Completer<void>();
    final entered = Completer<void>();
    const first = PlaybackAdjustments(speed: 1.1);
    const latest = PlaybackAdjustments(speed: 1.25, lockPitchToSpeed: true);
    when(() => handler.setPlaybackAdjustments(any())).thenAnswer((i) async {
      final values = i.positionalArguments.first as PlaybackAdjustments;
      if (values == first) {
        entered.complete();
        await gate.future;
      }
      applied.add(values);
      events.add(values);
    });
    final oldOperation = controller.setValues(first);
    await entered.future;
    final newOperation = controller.setValues(latest);
    await Future<void>.delayed(Duration.zero);
    events.add(first);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.values,
      latest,
    );
    gate.complete();
    await Future.wait([oldOperation, newOperation]);
    await controller.flush();
    expect(saved.last, latest);
  });
  test(
    'unsupported linked restoration retains speed and original presets',
    () async {
      const linked = PlaybackAdjustments(speed: 1.25, lockPitchToSpeed: true);
      final restored = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                playbackSpeed: 1.25,
                lockPitchToSpeed: true,
                playbackPresets: const [
                  PlaybackPreset(id: 'linked', name: 'Linked', values: linked),
                ],
                selectedPlaybackPresetId: 'linked',
              ),
            ),
          ),
          audioHandlerProvider.overrideWithValue(null),
          settingsRepositoryProvider.overrideWithValue(repository),
          playbackAdjustmentCapabilitiesProvider.overrideWithValue(
            const PlaybackAdjustmentCapabilities(),
          ),
        ],
      );
      addTearDown(restored.dispose);
      final state = await restored.read(playbackAdjustmentsProvider.future);
      expect(state.values.speed, 1.25);
      expect(state.values.pitchSemitones, 0);
      expect(state.values.lockPitchToSpeed, isFalse);
      expect(state.presets.single.values, linked);
      expect(state.failure, PlaybackAdjustmentFailure.unsupported);
      expect(
        await restored
            .read(playbackAdjustmentsProvider.notifier)
            .selectPreset('linked'),
        isFalse,
      );
    },
  );

  test('fractional changes flush exact values across panel lifetime', () async {
    const values = PlaybackAdjustments(speed: 1.1234, pitchSemitones: -1.37);
    await controller.setValues(values);
    await controller.flush();
    expect(applied.last, values);
    expect(saved.last, values);
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.selectedPresetId,
      isNull,
    );
  });
  test(
    'publishing an already hydrated engine retains the selected preset',
    () async {
      const values = PlaybackAdjustments(speed: 1.25, pitchSemitones: 2.34);
      when(() => handler.playbackAdjustments).thenReturn(values);
      final restored = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                playbackSpeed: values.speed,
                playbackPitchSemitones: values.pitchSemitones,
                playbackPresets: const [
                  PlaybackPreset(
                    id: 'nightcore',
                    name: 'Nightcore',
                    values: values,
                  ),
                ],
                selectedPlaybackPresetId: 'nightcore',
              ),
            ),
          ),
          settingsRepositoryProvider.overrideWithValue(repository),
          playbackAdjustmentCapabilitiesProvider.overrideWithValue(
            PlaybackAdjustmentCapabilities.android,
          ),
        ],
      );
      addTearDown(restored.dispose);
      await restored.read(playbackAdjustmentsProvider.future);
      final selections = <String?>[];
      final subscription = restored.listen(
        playbackAdjustmentsProvider,
        (_, next) => selections.add(next.asData?.value.selectedPresetId),
      );
      await restored
          .read(audioHandlerStateProvider.notifier)
          .setHandler(handler);
      await Future<void>.delayed(Duration.zero);
      final current = restored.read(playbackAdjustmentsProvider).requireValue;
      expect(current.selectedPresetId, 'nightcore');
      expect(current.pending, isFalse);
      expect(selections, isNot(contains(null)));
      verifyNever(() => handler.setPlaybackAdjustments(any()));
      subscription.close();
    },
  );
  test(
    'restores selected identity for a named zero-adjustment preset',
    () async {
      final restored = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                playbackPresets: const [
                  PlaybackPreset(
                    id: 'neutral',
                    name: 'Neutral',
                    values: PlaybackAdjustments(),
                  ),
                ],
                selectedPlaybackPresetId: 'neutral',
              ),
            ),
          ),
          audioHandlerProvider.overrideWithValue(handler),
          settingsRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(restored.dispose);
      final state = await restored.read(playbackAdjustmentsProvider.future);
      expect(state.selectedPresetId, 'neutral');
      expect(state.originPresetId, 'neutral');
    },
  );
  test('an edited preset keeps its origin through a restart', () async {
    const fast = PlaybackAdjustments(speed: 1.5);
    await controller.setValues(fast);
    await controller.savePreset('Fast');
    final id = container
        .read(playbackAdjustmentsProvider)
        .requireValue
        .selectedPresetId!;
    String? stored;
    const edited = PlaybackAdjustments(speed: 1.75);
    when(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    ).thenAnswer((i) async {
      stored = i.namedArguments[#selectedPresetId] as String?;
    });
    await controller.setValues(edited);
    await controller.flush();
    expect(stored, id);

    ProviderContainer restart(String? selected) => ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(
          AsyncData(
            const AppSettingsModel.defaults().copyWith(
              playbackSpeed: edited.speed,
              playbackPresets: const [
                PlaybackPreset(id: 'fast', name: 'Fast', values: fast),
              ],
              selectedPlaybackPresetId: selected,
            ),
          ),
        ),
        audioHandlerProvider.overrideWithValue(handler),
        settingsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    final restored = restart('fast');
    addTearDown(restored.dispose);
    final state = await restored.read(playbackAdjustmentsProvider.future);
    expect(state.selectedPresetId, isNull);
    expect(state.originPresetId, 'fast');
    // A stored id that no longer exists leaves no origin.
    final gone = restart('deleted');
    addTearDown(gone.dispose);
    expect(
      (await gone.read(playbackAdjustmentsProvider.future)).originPresetId,
      isNull,
    );
  });
  test('editing back to the origin values selects it again', () async {
    await controller.setValues(const PlaybackAdjustments(speed: 1.5));
    await controller.savePreset('Fast');
    final id = container
        .read(playbackAdjustmentsProvider)
        .requireValue
        .selectedPresetId!;
    await controller.setValues(const PlaybackAdjustments(speed: 1.75));
    var state = container.read(playbackAdjustmentsProvider).requireValue;
    expect((state.selectedPresetId, state.originPresetId), (null, id));
    await controller.setValues(const PlaybackAdjustments(speed: 1.5));
    state = container.read(playbackAdjustmentsProvider).requireValue;
    expect((state.selectedPresetId, state.originPresetId), (id, id));
  });
  test('rapid input keeps newest pair without an older late write', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    when(() => handler.setPlaybackAdjustments(any())).thenAnswer((i) async {
      final value = i.positionalArguments.first as PlaybackAdjustments;
      applied.add(value);
      if (applied.length == 1) {
        entered.complete();
        await gate.future;
      }
    });
    final first = controller.setValues(const PlaybackAdjustments(speed: 1.1));
    await entered.future;
    final middle = controller.setValues(const PlaybackAdjustments(speed: 1.2));
    final last = controller.setValues(
      const PlaybackAdjustments(speed: 1.3, pitchSemitones: 2.75),
    );
    gate.complete();
    await Future.wait([first, middle, last]);
    await controller.flush();
    expect(applied.length, 2);
    expect(applied.last.speed, 1.3);
    expect(saved.last.pitchSemitones, 2.75);
  });
  test('presets require explicit update, and deleting retains sound', () async {
    const original = PlaybackAdjustments(speed: 1.25, pitchSemitones: 3);
    await controller.setValues(original);
    expect(await controller.savePreset('Nightcore'), isTrue);
    final id = container
        .read(playbackAdjustmentsProvider)
        .requireValue
        .selectedPresetId!;
    await controller.setValues(
      const PlaybackAdjustments(speed: 1.4, pitchSemitones: 3.25),
    );
    var state = container.read(playbackAdjustmentsProvider).requireValue;
    expect(state.selectedPresetId, isNull);
    expect(state.originPresetId, id);
    expect(state.presets.single.values, original);
    expect(await controller.savePreset('Nightcore', updateId: id), isTrue);
    expect(await controller.renamePreset(id, 'Fast'), isTrue);
    expect(await controller.deletePreset(id), isTrue);
    state = container.read(playbackAdjustmentsProvider).requireValue;
    expect(state.values.speed, 1.4);
    expect(state.selectedPresetId, isNull);
    expect(state.presets, isEmpty);
  });
  test('None is immutable and reset retains user presets', () async {
    expect(await controller.savePreset('None'), isFalse);
    expect(await controller.deletePreset('none'), isFalse);
    expect(await controller.renamePreset('none', 'Changed'), isFalse);
    expect(await controller.savePreset('One'), isTrue);
    expect(await controller.savePreset(' one '), isFalse);
    await controller.setValues(const PlaybackAdjustments(speed: 1.125));
    await controller.selectPreset('none');
    final state = container.read(playbackAdjustmentsProvider).requireValue;
    expect(state.values.isNone, isTrue);
    expect(state.selectedPresetId, 'none');
    expect(state.presets.length, 1);
  });
  test('backend failure restores last applied pair and preset', () async {
    await controller.setValues(const PlaybackAdjustments(speed: 1.25));
    await controller.savePreset('Fast');
    final previous = container.read(playbackAdjustmentsProvider).requireValue;
    when(() => handler.setPlaybackAdjustments(any()))
        .thenThrow(StateError('failed'));
    expect(
      await controller.setValues(const PlaybackAdjustments(speed: 1.5)),
      isFalse,
    );
    final state = container.read(playbackAdjustmentsProvider).requireValue;
    expect(state.values, previous.values);
    expect(state.selectedPresetId, previous.selectedPresetId);
    expect(state.failure, PlaybackAdjustmentFailure.application);
  });
  test(
    'native failure during rapid input retains the newest linked preview',
    () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      const old = PlaybackAdjustments(speed: 1.1);
      const latest = PlaybackAdjustments(speed: 1.25, lockPitchToSpeed: true);
      when(() => handler.setPlaybackAdjustments(any()))
          .thenAnswer((invocation) async {
            final values =
                invocation.positionalArguments.first as PlaybackAdjustments;
            if (values == old) {
              entered.complete();
              await gate.future;
              throw StateError('native');
            }
            applied.add(values);
          });
      final first = controller.setValues(old);
      await entered.future;
      final last = controller.setValues(latest);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait([first, last]);
      await controller.flush();
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.values,
        latest,
      );
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.failure,
        isNull,
      );
      expect(saved.last, latest);
    },
  );
  test('persistence failure remains retryable', () async {
    when(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    ).thenThrow(StateError('disk'));
    await controller.setValues(
      const PlaybackAdjustments(pitchSemitones: -2.12),
    );
    await controller.flush();
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.failure,
      PlaybackAdjustmentFailure.persistence,
    );
    when(
      () => repository.savePlaybackAdjustments(
        values: any(named: 'values'),
        selectedPresetId: any(named: 'selectedPresetId'),
        presets: any(named: 'presets'),
      ),
    ).thenAnswer((_) async {});
    await controller.flush();
    expect(
      container.read(playbackAdjustmentsProvider).requireValue.failure,
      isNull,
    );
  });
  test(
    'late storage failure cannot replace a newer linked adjustment',
    () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      var writes = 0;
      when(
        () => repository.savePlaybackAdjustments(
          values: any(named: 'values'),
          selectedPresetId: any(named: 'selectedPresetId'),
          presets: any(named: 'presets'),
        ),
      ).thenAnswer((invocation) async {
        writes++;
        if (writes == 1) {
          entered.complete();
          await gate.future;
          throw StateError('disk');
        }
        saved.add(invocation.namedArguments[#values] as PlaybackAdjustments);
      });
      await controller.setValues(
        const PlaybackAdjustments(speed: 0.99, lockPitchToSpeed: true),
      );
      final oldSave = controller.flush();
      await entered.future;
      const latest = PlaybackAdjustments(speed: 1.25, lockPitchToSpeed: true);
      await controller.setValues(latest);
      final newestSave = controller.flush();
      gate.complete();
      await Future.wait([oldSave, newestSave]);
      expect(saved.last, latest);
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.values,
        latest,
      );
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.failure,
        isNull,
      );
    },
  );
  test(
    'unsupported pitch lock is rejected without changing a supported pair',
    () async {
      when(() => handler.playbackAdjustmentCapabilities)
          .thenReturn(PlaybackAdjustmentCapabilities.mediaKit);
      container.invalidate(playbackAdjustmentCapabilitiesProvider);
      const independent = PlaybackAdjustments(speed: 101);
      await controller.setValues(independent);
      expect(await controller.setPitchLock(enabled: true), isFalse);
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.values,
        independent,
      );
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.failure,
        PlaybackAdjustmentFailure.lockUnsupported,
      );
    },
  );
  test(
    'unsupported backend rejects pitch and preserves current sound',
    () async {
      when(() => handler.playbackAdjustmentCapabilities)
          .thenReturn(const PlaybackAdjustmentCapabilities());
      container.invalidate(playbackAdjustmentCapabilitiesProvider);
      expect(
        await controller.setValues(
          const PlaybackAdjustments(pitchSemitones: 1),
        ),
        isFalse,
      );
      expect(applied, isEmpty);
      expect(
        container.read(playbackAdjustmentsProvider).requireValue.values.isNone,
        isTrue,
      );
    },
  );
}
