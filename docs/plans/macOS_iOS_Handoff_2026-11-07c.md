# macOS/iOS coordinator hand-off (2026-11-07, third)

Rollover after three item PRs merged (owner rule in `~/.claude/CLAUDE.md`
"Context"). Supersedes [macOS_iOS_Handoff_2026-11-07b.md](macOS_iOS_Handoff_2026-11-07b.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (update its rows).

## State

- dev = `413dabc7` (before this hand-off PR). Merged this session:
  - #337 (`027d8a91`): uncaught-error stacks print one line per call (iOS cut
    single prints at ~1 KB, which hid the Riverpod stack).
  - #339 (`0322a8aa`): the debug-only Riverpod startup assertion, root cause
    proven at runtime (`serverConfigStateProvider` listeners in
    `ServerReachabilityController` and `LibrarySyncController` wrote state
    inside `NavisApp.build`'s flush). Fix: `runOutsideWidgetBuild` +
    `DeferredListenerGate` (`lib/src/utils/run_outside_widget_build.dart`),
    debug-only deferral while building, stale deferred deliveries dropped;
    release unchanged. The I0 router prewarm is deleted. Notes:
    [Riverpod_Startup_Assertion_2026-11-07.md](Riverpod_Startup_Assertion_2026-11-07.md).
  - #335 (`413dabc7`): **I9, EQ on iOS** via `MTAudioProcessingTap`
    (`third_party/just_audio/darwin/.../NavisEqualizer.m`, C DSP
    `NavisEqualizerDsp.c`, C test under ASan/UBSan in CI). Three review
    rounds (Sonnet high + Opus each); simulator proof in the I9 row and the
    PR body. Gated `TARGET_OS_IOS`; macOS unchanged (debug macOS AVFoundation
    receives no config).
- All branches and worktrees of this session are deleted. Not ours, left
  alone: `t3/ios-release-readiness-survey` worktree, `chore/macos-ios-readiness`.
- Simulator iPhone 17 (`CE8EF4B8-D441-4991-8F0F-DFA4BE4741AE`) is booted; the
  last install is a diagnostics build from the I9 branch (sign-in `navis`,
  password file `build/ios-diagnostics/password.txt`, mode 600, never print).

## In flight

Nothing: no open PRs of ours, no subagents, delegates or worker threads.

## Next steps

1. **Owner questions, when the owner is back (one question call):** the held
   I11 questions ([iOS_Parity_Plan.md](iOS_Parity_Plan.md), "Owner questions
   from I11"; note I9 has landed, so the AirPlay option (b) "transport left
   slot until I9" is moot) plus the I3 keychain choice `first_unlock`
   (current) vs `first_unlock_this_device` (password does not move to a new
   phone via backup).
2. **I10 transport slot:** verify on the simulator (app-owned screenshot)
   that the iOS transport row's left slot now shows the EQ button and opens
   the EQ screen; fix if still the invisible placeholder.
3. **I9 follow-ups (small, from reviews; listed in the PR #335 body):**
   attach the tap before `insertItem`; `tracksWithMediaType` deprecation
   (`loadTracksWithMediaType`); dispose drops `processedFrames`; banks built
   while holding `c->lock`; a stalled track load stays "attaching" (documented
   in `docs/features/equalizer.md`). None blocks release.
4. Small findings to triage (unchanged): `tool/sync_diagnostics.sh` pre-run DB
   summary crashes on the macOS database (`no such table:
   song_identity_aliases`); two `ping.view` errors at startup; end-of-sync
   state `partial`.
5. I2 (local network prompt), I4, I6 as small PRs; I5 device pass (ask the
   owner with notice; borrowed iPhone) now has I9's device checks: audible
   A/B, AirPlay route, lock screen with the tap, CPU on hi-res, interruptions.

## Owner actions and questions

- Held I11 questions and the keychain choice (above).
- Unchanged: paid Apple Developer Program; macOS hands-on pass; #266 and the
  desktop media-info dialog belong to the 1.5.2 session.
