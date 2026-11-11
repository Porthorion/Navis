# macOS/iOS coordinator hand-off, 2026-11-08 (b)

Previous: [2026-11-08](macOS_iOS_Handoff_2026-11-08.md). Ledger:
[iOS_Parity_Plan.md](iOS_Parity_Plan.md).

## State

- `dev` = `28e37361` plus this hand-off. This session merged three items, all
  risky native work in the shared iOS `MTAudioProcessingTap`, each with fresh
  Sonnet and Opus reviews, simulator proof and green CI:
  - **I21** independent pitch, #399 (`17d0d21a`).
    [Plan](iOS_I21_Pitch_Plan.md), renamed from the I10 plan.
  - **I25** EQ/pitch at each song's own format, #401 (`ba31f71e`), a 1.5.2
    blocker found in the I21 review. AVQueuePlayer builds one pipeline per run
    of same-format songs, and each one prepared the single shared tap at the
    next song's format, so the EQ was mis-tuned or missing after a format
    change. The fix is per-(rate, channels) slots kept until the tap is
    finalized. [Plan](iOS_I25_Format_Streams_Plan.md); a Fable advisor
    reviewed its lifetime rule.
  - **I24** ReplayGain boost on iOS, #403 (`28e37361`).
    [Plan](iOS_I24_ReplayGain_Boost_Plan.md). The 3 s guard and 500 ms hold
    are kept, as on other platforms.
- The format-change gap is about 0.43 s for rate changes and about 0.8 s for
  mono/stereo/float changes. It was the same before I25, it comes from
  AVQueuePlayer switching pipelines, and it is out of scope. Same-format joins
  are still about 0 ms.
- TestFlight: the last upload is still build 37332319 (from `e3a3fc73`), which
  predates I21, I23, I24 and I25.

## Next steps, in order

1. **Builds (owner, 2026-11-08):** from one `dev` commit (the merge of this
   hand-off or later):
   - the macOS dev app signed with the Apple Development cert (Team
     BFBNSCVKXH; see memory `macos-test-builds-from-dev`);
   - then a TestFlight internal build via `tool/release.sh --ios-upload`. Read
     `docs/release/release-ios.md` first. Credentials are in
     `tool/release.env` and `~/.appstoreconnect/private_keys/`; never print
     them.

   Run one heavy job at a time. Tell the owner when processing finishes so
   they can add the build to the internal group. That build is also the I5
   device pass (a borrowed iPhone).
2. **I5 device checks**, added by this session's items:
   - audible pitch and the 0↔non-0 splice, the tail at queue end, CPU at 96 kHz
     with pitch;
   - `/v1/equalizer` `overlapBlocks`, `clampedUnprepares` and `livePipelines`
     on real mixed-format queues: they must stay 0, 0 and balanced, because
     the I25 free-all is only safe while prepares and unprepares balance;
   - the boost level by ear, and Bluetooth/AirPlay output latency against the
     3 s guard window;
   - plus the lock screen, interruptions and AirPlay, as before.
3. **Ledger nits** carried over: CarPlay is 2.0.0 in `development-plan.md`
   but 1.6 in newer docs; note Mac App Store updater gating plus sandbox as a
   future macOS item.
4. **Known limits** recorded in the I24 and I25 plans: rate-less mid-song
   blocks, the per-slot busy-drop start, coarse clocks, the AVQueuePlayer
   error-skip, and tag-only timing with a wrong tag. Revisit only if I5 shows
   them.

## Worktrees and branches

- All of this session's worktrees and branches were deleted after merge:
  `i21-pitch`, `ios-i10-pitch-probe`, `i25-probe`, `i25-plan`, `i24`.
- Not ours, leave them: `~/.t3/worktrees/Navis/t3-*`.

## Owner actions open

- Demo server (separate coordinator), then the Beta App Review sign-in in App
  Store Connect.
- Add the new TestFlight build to the internal tester group when told.
