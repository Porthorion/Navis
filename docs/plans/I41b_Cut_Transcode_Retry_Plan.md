<!-- Opus plan 2026-11-10 for I41 follow-up (#527): a cut no-length transcode on mobile. Probe spec: build/i527b/probe/README.md (this Mac only). -->
# I41 / #527 follow-up: recover a cut no-length transcode on iOS (and Android)

Planner: Opus, 2026-11-10. Static reading only: no builds, tests or simulator.
Base: `dev` at 394647387.

## Cause

The premature-transcode-EOF retry (`_captureTranscodeEndOccurrence` and
`_retryPrematureTranscodeEnd`, `lib/src/features/player/data/navis_audio_handler_recovery.dart:491-640`)
has three problems on mobile:

1. **It is switched off.** `!_isDesktopRuntime` gates it (`recovery.dart:492`, `:540`).
   The successor-publish yield is gated the same way (`navis_audio_handler_media_session.dart:342`).
2. **It would reopen at the wrong second.** On mobile, the departure position it reads
   is a stale native stamp.
3. **Its invalidation guards would block it.** On mobile they compare that stale stamp
   with the Dart wall-clock time of the last invalidation.

### Q1: why the retry is desktop-only (settled)

- 03393250c ("fix: recover cut desktop transcodes at song position") states the scope
  in its own docs: "On desktop, a native auto-advance … can hide a cut transcode as a
  clean EOF" (`docs/architecture.md` near "On desktop, a native auto-advance").
  `docs/project/progress.md` scopes it as "item 11a PR C desktop transcode EOF".
- The tests run on the desktop handler (`navis_audio_handler_navigation_test.dart:12629`,
  group 'premature transcode EOF'). The only mobile cases there are seek-preview cases.
- 9b7b47f0d only keeps the recovery intent through shutdown and queue work. It adds no
  platform reasoning.
- The one part that is genuinely mpv-specific is where the departure position comes from.
  The doc says "Native duration and the interpolated desktop clock do not establish the
  departure position". So capture reads `event.updatePosition`, which media_kit emits
  densely.
- **Conclusion:** desktop-only reflects where the bug was seen and tested. The detection
  and recovery logic is platform-neutral Dart. It reuses `_retryRemotePlayback`
  (`recovery.dart:1970`), which already serves iOS and Android error recovery.
- **Android (static, not run):**
  - just_audio's `AudioPlayer.java:435-444` stamps `updatePosition()` for the *new* item,
    then broadcasts. The departing event is as sparse as on iOS.
  - ExoPlayer treats a clean close of an unknown-length progressive stream as end of
    input. That is an auto transition, or `ended` on the last item, with no error, so it
    has the same hole.
  - A reset (RST) becomes an IOException. After ExoPlayer's load retries it surfaces as
    an error, and the existing error recovery (`_recoverCurrentSongFromRemotePlaybackFailure`)
    covers that.

### Q2: what iOS emits on a cut, and whether the desktop logic fits (settled statically)

All references are to `third_party/just_audio/darwin/just_audio/Sources/just_audio/AudioPlayer.m`.

- **Mid-queue cut.** `AVPlayerItemDidPlayToEndTime` calls `onComplete` (`:1234-1252`):
  `_index = next; [self broadcastPlaybackEvent]`, **without** `updatePosition`.
  - The Dart pairwise detector (`third_party/just_audio/lib/just_audio.dart:167-185`)
    then emits `autoAdvance`. Its `previousEvent` carries the last native stamp: from
    load/ready/seek, or a #526 re-stamp, which happens at most once a second and only on
    drift (`:726-741`). A cleanly draining cut does not drift, so the stamp is usually the
    ready stamp near 0.
  - The desktop retry then takes `position = previousEvent.updatePosition` (`recovery.dart:581-583`)
    and reopens at about 0 s, not at the cut.
- **Final-item cut.** `complete` calls `updatePosition` before broadcasting `completed`
  (`:1554-1557`), so the completed event holds the real end position. The 13.18 s in
  `build/i527/.../run3` s_mp3end matches this.
  - `_continueIntoDeferredTail` (`navis_audio_handler_queue_window.dart:191`) already
    calls the retry. **Removing the gates alone fixes the final-item case.**
- **Failed to play to end.** `onFailToComplete` is a no-op (`:1229`). The FINDINGS
  evidence shows that RST and clean close both end as `completed`.
- **Queue edits.** `concatenatingInsertAll`/`RemoveRange`/`Move` broadcast without
  `updatePosition` (`:704`, `:723`).
  - `_invalidateTranscodeEndOccurrence` runs on every queue edit
    (`queue_editing.dart:250,254`), on queue work (`queue_loading.dart:10`) and on
    transport changes (`navigation.dart:10`). It stores `DateTime.now()`.
  - On mobile, both guards compare that time with a native `updateTime` that does not
    move after an edit: `!event.updateTime.isAfter(invalidated)` in capture (`:497`) and
    in retry (`:569-570`).
  - **Result:** after a mid-song queue append (Same Vibes, tail release) the cut is
    ignored until the next native re-stamp.
- **Offset time base (settled).** The fork adds `positionOffset` to `updatePosition` when
  it converts the event (`just_audio.dart:1762-1776`). `position` comes from
  `_getPositionFor(playbackEvent)` (`:700-709`). Both share the song time base, so an
  offset continuation is safe.
- **Discontinuity ordering.** The pairwise detector subscribes before the
  sequence-state/currentIndex chain (`just_audio.dart:167` vs `:208-213`). Desktop still
  yields one microtask (`media_session.dart:342`) so the discontinuity claims the cut
  before the successor is published. Mobile needs the same yield.

### The existing evidence would not have triggered the retry, even on desktop

- The i527 runs used `format=original`, so `transcodingApplied` was false (main-navis.log
  shows `format=original`).
- The fixture advertises no `transcodeOffset` (`tool/auth_lifecycle_fixture_server.py:564-565`).
- Every `completed` run had `queueLength 1`. "Skips in a queue" was never observed on iOS.
- The runtime pass below fixes all three.

### Q3: interactions (settled statically)

- **Radio (#539):** excluded by `_radioStation != null` in the retry (`:548`) and in
  `_continueIntoDeferredTail`. A radio `completed` goes to `_beginRadioRecovery`
  (`media_session.dart:285-288`). No change.
- **Watchdog:** a `completed` or advanced item does not stall. `_retryRemotePlayback`
  sets `_remotePlaybackRecoveryInProgress`, which the retry checks, and it shares the
  `_remotePlaybackRecoveryAttempts` `'$transportGeneration:$songId'` budget. A cut that
  the watchdog or error path already retried is not retried twice.
- **Crossfade (iOS deck):** the retry is skipped while `_isCrossfading` or
  `_crossfadeHandoffInProgress`. A cut before the fade window is a plain advance or
  completion and is retried.
  - **Risk:** removing the `:342` gate puts a microtask before *every* mobile index
    change. That listener also drives the crossfade deck handover. See Risks.
- **Gapless:** AVQueuePlayer's native queue raises the same `onComplete` advance. Covered
  by the mid-queue case.
- **#526 re-stamp (#550):** this only adds fresher stamps. If the newest event is a
  re-stamp later than the last sample, the retry uses that stamp, which is correct within
  200 ms. Otherwise it uses the sample. Nothing to change.

## Fix (minimal, one file plus one line)

All changes are in `navis_audio_handler_recovery.dart`, plus one line in `media_session.dart`.

1. **Remove the gates.** Drop `!_isDesktopRuntime ||` from `_captureTranscodeEndOccurrence`
   (`:492`) and `_retryPrematureTranscodeEnd` (`:540`). In `media_session.dart:342`, make
   the yield unconditional: `await Future<void>.value();`.
2. **Mobile capture uses the player clock.** In `_captureTranscodeEndOccurrence`, when
   `!_isDesktopRuntime`, store `position: _player.position, updateTime: DateTime.now()`
   instead of `event.updatePosition/updateTime`.
   - Desktop is unchanged: it keeps the backend position, as its doc requires.
   - The 100-200 ms position-stream sampler already calls capture
     (`media_session.dart:502`), so the sample is at most about 200 ms stale. The reopen
     floors to whole seconds.
   - The retry's existing choice needs no change:
     `previousEvent.updateTime.isBefore(occurrence.updateTime) ? occurrence.position : previousEvent.updatePosition`.
     A stale advance stamp falls back to the sample. The fresh `completed` stamp is used.
3. **Mobile invalidation guards use Dart time.**
   - In capture, use the same mobile `stamp` (`DateTime.now()`) for the `invalidated`
     comparison. In practice it always passes; invalidation already nulled the occurrence.
   - In the retry, on mobile compare `occurrence.updateTime` with `invalidated` instead
     of `previousEvent.updateTime`.
   - Keep the rest unchanged: the source-identity and index checks, and recover()'s
     re-check `departedIndex < 0 || id mismatch → return`. They stop a removed current
     item from being reopened.
   - Implement both as one local `final stamp = _isDesktopRuntime ? event.updateTime : DateTime.now();`.
     Add no new fields, helpers or classes.
4. **Docs:** in `docs/architecture.md`, change the "On desktop, a native auto-advance…"
   paragraph so the retry applies on all platforms, with the mobile position source
   stated in one sentence. Add a changelog line.

Infrastructure reused (no parallel implementation):
- `_retryRemotePlayback` and its retry budget, `_prematureTranscodeDeparture` hold and
  pause, `_continueIntoDeferredTail`, and `_onPositionDiscontinuity`.
- The position-stream sampler and `_invalidateTranscodeEndOccurrence`.
- The fake `_ControllableAudioPlayer`, with its `nativePositionFrozen` knob.

**Android: in scope by construction.** The Dart is shared, and the gate removal plus the
mobile clock cover ExoPlayer's equally sparse departing event. It is covered by unit
tests only: no runtime pass this round (the 8 GB Mac runs one emulator). Add an Android
runtime pass with the same fixture as a follow-up. If the owner wants Android out, the
gate becomes `_isDesktopRuntime || iOS`. That is not recommended, because Android has the
same clean-close hole.

## Failing tests first (navigation_test.dart, group 'premature transcode EOF', `:12629`)

**Fake change.** Extend the existing `nativePositionFrozen` knob, not a new fake. When it
is set, `playbackEvent` (`:819`) also returns a frozen `updateTime`: the time
`simulatedPosition` was last set by a load or seek, not by `finishCurrentTrack`. This
models AVQueuePlayer's stale advance stamp. `position` keeps extrapolating
(`simulateProgress`). `setup()` gets a `bool mobile = false` that passes
`desktopRuntimeOverride: false` and sets the frozen stamp at 0.

Tests:

1. `reopens at 47 of 300 seconds (last: false, mobile)`: the stamp is frozen at 0 and the
   clock runs to 47 s, then `finishCurrentTrack(endPosition: 47s)` runs.
   - Expect `timeOffset=47`, the same song and index, and playing.
   - With only the gates removed, this fails at `timeOffset=0`. That proves step 2.
2. `reopens … (last: true, mobile)`: passes with the gates removed alone, because
   `complete` re-stamps. Keep it as a regression test.
3. `a second early end does not loop (mobile)`, both `last` values.
4. `queue edit then cut (mobile)`: run a queue append mid-song, then the cut. Expect a
   reopen at 47. This fails before step 3.
5. Parameterize on mobile: `'queue edit $edit is not a transcode cut'` (`:13483`),
   `'a user skip does not reopen the departed song'` (`:13787`) and
   `'$gate keeps normal advance'` (`:13673`).
6. `position stream across a cut reload (#210)` hold, mobile: no next-item 0 is published
   (this covers the `:342` yield).
7. Run the crossfade handover tests and the iOS handler tests with
   `desktopRuntimeOverride: false` and confirm they still pass after the `:342` change.

Run only the touched files in the foreground, capped (8 GB Mac):
`flutter test test/src/features/player/data/navis_audio_handler_navigation_test.dart --plain-name 'premature transcode EOF'`,
then the crossfade test file. The coordinator then runs `./tool/check.sh` once.

## Edge cases

- **Removed current item on mobile:** recover() finds `departedIndex < 0` and does not
  reopen. The pause is released (row 15 tests).
- **Seek then cut:** the occurrence is re-sampled after the seek because the source is
  identical. The worst case is a sample up to 200 ms stale.
- **Paused when the cut drains:** `_latestExplicitTransportPlaying == false` already
  blocks the retry.
- **Repeat One on iOS:** `onComplete` seeks to 0 with no index change, so the pairwise
  detector flags a loop only if `prevPos >= 0.6 × duration`. An early cut under Repeat
  One may be missed. That is acceptable: normal behaviour, no regression.
- **Overstated server duration:** the existing ponytail ceiling (10 s margin) applies
  unchanged.
- **Lock-cached transcode on iOS:** the reopen goes through the existing source resolver
  (`transcodeOffset` → `_buildStreamUri` with `timeOffsetSeconds`).

## Runtime verification (Flash, after the fix builds)

Spec and fixture patch: `build/i527b/probe/README.md`. Required lines:

- `PASS final`: the second `stream` request for the song has `timeOffset` 12-14, and
  within 20 s status shows the same `songId` playing at `playerPositionMs >= 13000`.
- `PASS mid-queue`: same for index 1 of 3, and `currentIndex` stays 1 until the song ends
  near 60 s.
- `PASS edit-then-cut`: append to the queue at about 5 s, then cut. Same outcome.
- **Evidence:** the `anomalies` `disc` event in the status dump shows a stale
  `updateTimeAgoMs` (over 5 s) at the advance. This confirms the static Q2 reading.
- Optional baseline on `dev` before the fix: all three print `FAIL` (stop or skip, with
  no second request).

## Risks

- **The `:342` yield on every mobile index change:** a microtask delay in the crossfade
  deck handover and in metadata publishing. Mitigated by test item 7 and the crossfade
  check in the runtime pass.
- **The mobile clock sample:** `_player.position` extrapolates only while playing and
  ready. A buffering stall right before the end gives a lower position, which is the safe
  direction (it replays a little).
- **Retrying a real end:** with server metadata that overstates the duration, a real end
  is retried on mobile too. The ceiling and budget are unchanged: one retry per song per
  transport generation.
- **Review class:** a playback state machine, so Sonnet `high` review is required.

## Fix round 2 notes

Root cause: `build/i527b/ROOT_CAUSE.md` (Opus, runtime-proven). Three fixes:

- **A (fork):** `just_audio.dart` treats a zero platform duration as unknown (null), so
  `_getPositionFor` no longer clamps at the offset. Readers of the player duration were
  audited: all accept null.
- **B (app):** `recover()` evicts the song's rolling entry (`evictRollingTrack`, rolling rows
  only) when the source kind is `lockCachedStream`, then re-checks the invalidation guards
  before reopening. An eviction error is logged and the reopen still runs once.
- **C (app):** the recovery pause runs in a microtask, outside the player's event dispatch.
  The fake cannot model a synchronous controller; the runtime probe must show no
  "Pause before transcode recovery failed" line.

## Fix round 3

Root cause: `build/i527b/ROOT_CAUSE_2.md` (D1) with the Fable advice `FABLE_ADVICE.md`.

- **D1:** `_captureTranscodeEndOccurrence` (mobile only) records nothing while
  `_sourceAppliesInFlight > 0` or the native state is idle/loading, and an index event in
  either state clears the held occurrence. `_retryPrematureTranscodeEnd` returns false when an
  apply is in flight or the previous event was idle/loading. Desktop capture is unchanged;
  the retry guards are platform-neutral and the desktop tests stay green.
- **Tests:** the fake player gained `staleSequenceSwap` (the sequence swaps under the old
  item's index, position and ready state, then a tick, then loading) and
  `useRealDiscontinuityDetector` (just_audio's pairwise detector). The negative tests fail on the
  previous head and with only the idle/loading gates. The positive test (a real cut after the swap
  reopens once at 47 s) passes before and after.
- **Tail fill:** `_fillQueueBatch` uses `addAudioSources`/`insertAudioSources`, never the counted
  `_setAudioSourcesWithFallback`, so the apply gate does not block a cut during the tail fill.
  While the tail fill runs the queue items do not match the native sequence, so the mobile sampler
  does not refresh the occurrence; a cut then reopens at the position sampled at the index
  event (about 0 s, where such a cut happens in practice).
- **Not reproduced:** the shift case (old index 1, new start 0) needs a first apply with two sources;
  the test queue's first apply carries one, so only the same-index case is exercised.
- **R1:** `_pendingRollingRegistrations` (by song) holds the registration started at 1.0 progress;
  `recover()` awaits it before evicting. Test: a download finishing as the cut is judged leaves
  neither the file nor the row.
- **R2:** `deleteCachedTracksBySongIds(rollingOnly: true)`, used by `evictRollingTrack`, so a
  permanent row is never deleted between its read and the delete.
