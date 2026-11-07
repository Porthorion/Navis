# macOS/iOS coordinator hand-off (2026-11-07, second)

Rollover after three item PRs merged (owner rule in `~/.claude/CLAUDE.md`
"Context"). Supersedes [macOS_iOS_Handoff_2026-11-07.md](macOS_iOS_Handoff_2026-11-07.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (update its rows).

## State

- Merged this session: #323 (previous hand-off), #322 (I0 simulator diagnostics),
  #325 (I3 keychain), #327 (anomaly recorder false positive), #329 (owner
  decisions), and — if green before this hand-off merged — #328 and #330 (see
  "In flight" for whichever are still open).
- Owner decisions 2026-11-07 (in the plan): iOS does not ship without EQ (I9);
  one shared design plus iOS conventions, no Cupertino overhaul (I10); feature
  research done (I11), its questions are **held until the owner is back**
  (owner asleep; they said to keep working and wait only when an answer is
  required).
- Test account: diagnostics clones and simulator sign-ins use the disposable
  server account `navis`. Plain-password file
  `build/ios-diagnostics/password.txt` (mode 600, git-ignored, main checkout);
  launch with `NAVIS_DIAGNOSTICS_DEVICE=ios NAVIS_DIAGNOSTICS_USERNAME=navis
  NAVIS_DIAGNOSTICS_CREDENTIAL_PATH=<abs path>`. Never print it. The simulator
  (iPhone 17, `CE8EF4B8-D441-4991-8F0F-DFA4BE4741AE`, booted) has a normal debug
  build installed and signed in as `navis`.

## In flight

- **#328** `fix(player): apply playback settings after the settings stream
  updates` (crossfade-off never reached the handler; every platform). Reviewed
  (Sonnet high, nothing blocking; error logging added). Worktree
  `.claude/worktrees/agent-aaefb664149c67e34`. Merge when CI is green.
- **#330** `feat(ios): shorter bottom navigation bar on iPhone` (I10 part 1).
  Reviewed (Sonnet high, nothing blocking). Worktree
  `.claude/worktrees/agent-aa5fc2f2d95738fec`. Merge when CI is green.
- After merging: delete the branches and worktrees (check nothing symlinks into
  them), mark I1 runtime-done and I10 nav bar merged in the plan if not already.
- Nothing else running. No subagents or worker threads.

## Next steps

1. **I9 (EQ on iOS), risky: Sonnet build from this Opus plan**, then Sonnet
   `high` review and a fresh Opus review before merge, then simulator runtime
   proof. Plan (all native paths under
   `third_party/just_audio/darwin/just_audio/Sources/just_audio/`):
   - `NavisEqualizerDsp.c/.h`: C port of Android's `EqualizerDsp.java`, same
     behaviour (cookbook biquads, auto-headroom, per-channel history, banks
     built off the audio thread, swapped at block boundaries with a 20 ms
     crossfade). Hand-written loops, no vDSP setup on the audio thread.
   - `NavisEqualizer.m/.h`, one per player: decode/validate the same config map
     Android uses; `attachToItem:` creates an `MTAudioProcessingTap` and an
     `AVMutableAudioMix` after `loadValuesAsynchronouslyForKeys` on the asset's
     tracks (first audio track); the tap stays installed when EQ is off and
     bypasses (changing the mix on a playing item can drop out); `state` returns
     Android's keys (`enabled`, `sampleRate`, `headroomDb`, `reason`,
     `pending`) plus new optional `processedFrames` and `levelDeltaDb`.
   - Audio thread: no locks, allocation or Objective-C; atomic pointer to the
     next bank; old banks freed on the main thread after the audio thread
     acknowledges; ref-counted tap context (finalize may run late, on another
     thread). Non-float or interleaved formats pass through with a `reason`.
   - `JustAudioPlugin.m:33-38` passes `equalizerConfiguration` to `AudioPlayer`;
     `AudioPlayer.m` creates the equalizer only with a config, attaches at every
     item insertion (`:224,572,579,663`, and `playerItem2` in
     `UriAudioSource.m:170`), adds `setEqualizer`/`getEqualizerState` before
     `:184`, releases in `dispose`. Link MediaToolbox in the podspec and
     `Package.swift`. `NAVIS_CHANGES.md` entry.
   - Dart: `eq_platform_support.dart` gains `ios` (supported on iOS regardless
     of media_kit); macOS stays libmpv-gated, Android/desktop unchanged. The
     handler already sends config to both crossfade players.
   - Tests first: platform-support matrix; `EqualizerStateMessage.fromMap` with
     the new fields; diagnostics `/v1/equalizer` includes them; a clang-built C
     test of the DSP mirroring `EqualizerDspTest.java`.
   - Runtime proof (simulator, diagnostics API): `sampleRate` non-null and
     `pending` false; `processedFrames` grows while playing; flat filters with
     preamp −12 dB and auto-headroom off give `levelDeltaDb` ≈ −12, EQ off ≈ 0;
     on a local file, a proxied stream, across a gapless change, with
     crossfade on, at 1.5× speed.
   - Device-only (I5, borrowed iPhone, ask with notice): audible A/B, AirPlay
     route, lock screen with the tap, CPU on hi-res files, interruptions.
2. Riverpod startup assertion ("Tried to modify a provider while the widget
   tree was building"): seen twice on fixture runs even with the I0 prewarm,
   never on the real-server run; stack truncated. Opus root cause, then remove
   the prewarm (I0 row follow-up).
3. Small findings to triage: `tool/sync_diagnostics.sh` pre-run DB summary
   crashes on the macOS database (`no such table: song_identity_aliases`);
   two `ping.view` errors at startup; the end-of-sync state `partial`.
4. I2 (local network prompt), I4, I6 as small PRs; I10 transport slot waits on
   I9 and the AirPlay question.

## Owner actions and questions

- Held I11 questions: [iOS_Parity_Plan.md](iOS_Parity_Plan.md), "Owner
  questions from I11". Ask them in one question call when the owner is back.
- Open choice from the I3 Opus review: keychain `first_unlock` (current, plan)
  vs `first_unlock_this_device` (password does not move to a new phone via
  backup; user signs in again). Ask with the I11 questions.
- Unchanged: paid Apple Developer Program; Apple Development cert done; macOS
  hands-on pass; #266 and the desktop media-info dialog belong to the 1.5.2
  session.
