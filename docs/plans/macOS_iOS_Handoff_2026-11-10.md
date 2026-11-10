# macOS/iOS coordinator hand-off, 2026-11-10

Replaces [the 2026-11-09 (c) hand-off](macOS_iOS_Handoff_2026-11-09c.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (I32-I35). Rolled over after
five item PRs merged (#491, #492, #493, #495, #498).

## State

- 1.5.2 follow-ups I32/I33 merged and runtime-checked (#454, #456, #459).
- Sweep #478/#479, macOS/iOS half (owner prompt 2026-11-10; the release/1.5
  coordinator, ledger #209, owns the rest): **all done on `dev`**.
  - #478: a+b #492 (macOS `ios` CI job runs `xcodebuild test` for
    `macos/RunnerTests`, `macos_update_test.dart`, `libmpv_fetch_macos_test.sh`;
    TEST_HOST fixed to `Navis.app`), i #495 (tap layout predicates in
    `NavisTapFormats.c`, portable tests), j #491 (stale undeletable handshake).
  - #479: a+g #498 (first song's ReplayGain cut once its source is loaded;
    macOS runtime PASS, `build/479a-runtime/20261110T075345Z/`), d+e closed as
    not defects with a regression test #493, f filed as #489 (iOS haptic kinds),
    #490 (macOS boost) and a comment on #392 (iOS cut via player volume).
  - Status posted on #209 and on #478/#479 (comments, not body edits). The
    release/1.5 coordinator closes #478/#479 when its halves land.
- New issue #496: macOS mpv position steps back (81→14 ms) when load phase 2
  appends its window; untriaged.
- Open PRs not ours: #414 (1.6 live mode design), #486 (release/1.5 tooling).

## Owner actions

- I5 device-pass results from TestFlight 1.5.2 (37437428). Add to that pass
  (479d/e): with pitch on, repeated seeks at +12 semitones (no clicks; ~93 ms
  extra silence per seek is expected), first song start (no unpitched blip),
  a 44.1→48 kHz queue change (no unpitched blip).
- No `dev` TestFlight build (no real iPhone Duo; simulator runs accepted).

## Next steps

1. Wait for the owner's I5 results; triage anything they find.
2. Candidates for 1.6 triage with the owner: #489, #490, #496, #392 (iOS
   per-song cut), the 479a residual (a manual skip during load phase 2 plays
   the target with the previous cut until the commit).

## Notes learned

- The sweep survey (`~/.cache/claude-navis-logs/batch-152/sweep-survey.md`)
  lives on the Linux machine, not this Mac.
- macOS plays through mpv (media_kit), not AVPlayer; it shares the Dart
  ReplayGain cut path with iOS only because `navisReplayGainInPipeline` is off
  on macOS.
- Docs-only PRs get only `no-session-links`; merge with `--admin`.
- T3 device tools cannot boot Android emulators here (`avdmanager` needs JDK 17,
  default Java is 1.8) and do not list iPad simulators.
- `test (n)` rows in `gh pr checks` have a space in the name; split on tabs.

## Worktrees and branches

- None of ours. Older clean T3 worktrees from earlier coordinators remain
  (`t3-1187c7d6`, `t3-2409cd4e`, `t3-45692a45`, `t3-5cc396e7`, `t3-b723854b`,
  `t3-fee050b4`); left for their threads.
