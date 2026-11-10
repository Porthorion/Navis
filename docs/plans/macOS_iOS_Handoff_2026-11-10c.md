# macOS/iOS coordinator hand-off, 2026-11-10 (c)

Replaces [the 2026-11-10 (b) hand-off](macOS_iOS_Handoff_2026-11-10b.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (I26, I36-I40). Rolled over
on context before a long build (two item PRs merged: #515, #518).

## State

- I39 #490 macOS ReplayGain boost: merged #515 (`ee27b6c9`) on `dev`. macOS
  mpv now carries cut and boost in the `@navis_rg` filter like Linux/Windows.
  Runtime PASS `build/i39/20261110T104612Z/`.
- I38 iOS simulator runtime PASS `build/i38-ios/20261110T105407Z/` (control on
  the pre-fix commit shows the held cut).
- Backport: #518 (`25b9d596`) on `release/1.5` = #246 (late stream failure
  recovery; #498/#511 depend on its fields), #498, #512, #511. Fresh review
  nothing blocking; macOS release/1.5 profile runtime PASS
  `build/r15/20261110T121550Z/` (diagnostics needed dev's macOS gate patch in
  the throwaway build only). Not backported: #515 (release/1.5 macOS bundles
  libmpv 0.36, see `docs/release/release-macos.md:72` there), I36 (iOS ships
  from `dev`, owner decision 2026-11-08, `iOS_Parity_Plan.md:119`). Posted on
  #209.
- #392 D1-D7 were decided by the owner on 2026-11-08 (target 1.5.2; D4 iOS
  now; D5 done by I39). Phases 1, 2, 3, 5 are merged. Only phase 4 (iOS, I26)
  remains. Earlier hand-offs wrongly listed D1-D7 as open.
- I26 (#392 phase 4): design changed (Opus + Fable advisor, exception 2):
  since I23 the tap is shared and has no item identity. Phase A puts the cut
  in each item's audio-mix volume; boost unchanged. Spikes
  `build/i26-spike/20261110T125231Z/`. **Plan:
  [iOS_I26_ReplayGain_Cut_Plan.md](iOS_I26_ReplayGain_Cut_Plan.md), ready to
  build** (Sonnet build, fresh Sonnet review + fresh Opus review since it is
  risky playback, iOS simulator runtime pass per plan §6).

## Owner actions

- I5 device-pass results from TestFlight 1.5.2 (37437428) with the 479d/e
  pitch checks.
- Does the macOS boost (I39) ship in 1.5.2? Yes means moving `release/1.5` to
  dev's macOS libmpv pin (`libmpv-macos-universal-lgpl-20261104`) plus a
  runtime check; no means it reaches macOS in 1.6.
- To measure I26's output frame-exactness on this Mac: grant the T3 Code app
  "System Audio Recording Only" (Privacy & Security, Screen & System Audio
  Recording), or check by ear on a device (a −12 dB song followed by an
  untagged/0 dB song: the level must change exactly at the join).

## Next steps

1. Build I26 phase A from the plan (worktree from `dev`), reviews, simulator
   runtime pass, merge.
2. Output-exactness measurement once the owner grants capture (or device
   check), then decide the fixed-G exact-boost follow-up.
3. Triage the owner's I5 results when they arrive.

## Notes learned

- `link_pull_request` makes T3 settle the thread when the PR merges: in the
  coordinator, unlink before merging.
- `release/1.5` is not branch-protected; backports squash-merge like its
  other PRs.
- macOS profile builds of `release/1.5` need dev's diagnostics gate change
  (`90e03bd66`) to use the diagnostics API.

## Worktrees and branches

- None of ours remain (I39, backport, runtime and review worktrees removed;
  remote branches deleted). Older T3 worktrees from earlier coordinators
  remain (`t3-1187c7d6`, `t3-2409cd4e`, `t3-45692a45`, `t3-5cc396e7`,
  `t3-b723854b`, `t3-fee050b4`).
