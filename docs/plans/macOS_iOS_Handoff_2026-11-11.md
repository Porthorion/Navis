# macOS/iOS coordinator hand-off, 2026-11-11

Previous: [macOS_iOS_Handoff_2026-11-10d.md](macOS_iOS_Handoff_2026-11-10d.md). Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md).
Rollover reason: three item PRs merged this round (#547 I42, #550 I45, #562 I46).

## State

- `dev` at `c890749e` (#562). Main checkout clean on `dev` after this docs PR.
- Merged this round:
  - #544 docs.
  - #547 I42 #528 (Varispeed when locked).
  - #550 I45 #526 (position re-stamp).
  - #562 I46 iPad cover.
- No live worker threads, no running delegates.
- Owner decisions (2026-11-10/11):
  - Do **not** release or tag 1.5.2.
  - All 1.6 features stay in 1.6 or later.
  - **iPad compatibility is wanted in 1.5.2.** It is done: I46 merged; portrait pass is clean on the iPad Pro 13 and mini; landscape and Split View are covered by layout tests.
  - Coordinator decision, not yet owner-confirmed: the 11-inch and 10th-gen iPad in portrait keep the bottom bar.

## I41b (#527 follow-up): next step, then merge

Branch `fix/i527b-cut-transcode` at `da8c49f3f`, worktree `/Users/khalifaalzarooni/Documents/forgejo_projects/Navis-i527b`. Not pushed. Rebased on `b8be8a347`; rebase again on current dev.

- Plan: `docs/plans/I41b_Cut_Transcode_Retry_Plan.md`.
- Causes: `build/i527b/ROOT_CAUSE.md` and `ROOT_CAUSE_2.md`.
- Fable advice (logged exception (2)): `build/i527b/FABLE_ADVICE.md`.
- Runtime: the round-3 iOS probe is accepted as 3/3.
  - Every cut song reopened once at about 11.9 s for a cut at 12 s.
  - No spurious reopen of a song that wasn't cut; no pause error.
  - The server floors the time offset to whole seconds, so the probe window is now 11-14.
- Reviews:
  - Opus (file writes): nothing blocking.
  - Sonnet: no functional blocker.
- **Decision taken:** accept the platform-neutral desktop effects. Both reviews found them harmless:
  - the retry guards (an apply in flight, previous event idle/loading);
  - the microtask pause;
  - the zero duration treated as unknown, which Opus judged an improvement for media_kit song switches.
  - Record this in the PR body.
- **One small Sonnet round, then PR:**
  1. `_pendingRollingRegistrations` cleanup removes the entry only if it is still the same future (Opus low 2, `navis_audio_handler_cache.dart:441-445`).
  2. Add a failing-first test for the second `stale()` re-check after eviction (`recovery.dart:~671`): a skip during the eviction await must not reopen. Optionally add tests for the idle/loading gates and the index-event clear (removing each currently fails no test).
- Then:
  - check.sh: in a fresh worktree run `flutter pub get` in `third_party/navis_windows_smtc` first.
  - Push, PR to dev, CI (wait for `ci`, not only no-session-links), unwatch, unlink, squash-merge.
  - Delete the branch, the Forgejo mirror branch and the worktree.
- Known limits for the PR body:
  - A cut during a mid-queue tail fill reopens at a stale (about 0 s) position.
  - A server duration overstated by more than 10 s also retries a real end and evicts a valid rolling file (existing ceiling).
  - The eviction awaits have no timeout.
  - Android has no runtime pass.
  - The song-5 early end (D2) in round 2 did not recur in round 3.

## Remaining #527 items

- Empty queue after a failed first load.
- Restart-only playback break: waiting on owner diagnostics export after the next occurrence. Hypothesis: media services reset.

## Owed device checks (owner, hands-on)

- I42: live algorithm switch, locked 1.25 quality, EQ retune lag.
- I45: event count over long play, stream above 2x, Bluetooth.
- I26: device check.
- I5: TestFlight pass.
- I46: a real iPad in landscape and Split View, if available.

## Tooling notes

- Xcode 27 has no Simulator.app: simctl boots headless and rotation can't be scripted. iPad pass scripts are in `build/ipad/` (run_ipad.sh, analyze_ipad.py; fixture album id `fixture-album`).
- Goldens only compare on Linux. To regenerate, use Docker (`ghcr.io/cirruslabs/flutter:3.44.0`, linux/amd64) plus a Flutter 3.47.5 clone. The image (~1.5 GB) is cached locally.
- `tool/check.sh` blocks on drift's multiple-database warning. The I21 pitch test was split in #562.

## Worktrees and branches

- Live: `Navis-i527b` (`fix/i527b-cut-transcode`).
- Older `.t3/worktrees/Navis/*` belong to earlier coordinators and other items; leave them.
- I46 branch and worktree deleted (GitHub auto-deleted the branch; mirror deleted).
