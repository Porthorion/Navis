# macOS/iOS coordinator hand-off, 2026-11-10 (d)

Replaces [the 2026-11-10 (c) hand-off](macOS_iOS_Handoff_2026-11-10c.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (I26, I41-I45) plus the
GitHub issues named there. Rolled over after three item PRs merged (#520,
#522, #539). Global rules changed this round: `~/.claude/CLAUDE.md` gained
"Agent size and cache" (bounded briefs; runtime/evidence passes go to Flash
with an Opus-written script) and new Fable exceptions; read it first.

## State

- I26 (#392 phase 4, phase A): merged #522 (`e0af2003`). Fresh Sonnet and
  Opus reviews nothing blocking; iOS simulator runtime PASS
  `build/i26-ios/20261110T140338Z/`. Owed: device check by ear (live
  re-assign click) and output frame-exactness capture.
- #520 (hand-off c + I26 plan) merged as admin (docs-only PRs skip `ci`, see
  the comment at the top of `.github/workflows/ci.yml`).
- New owner reports filed and triaged (owner approved 2026-11-10):
  - I41 #527 playback never recovers: radio fixed and merged in #539
    (`34170299`), runtime PASS. Restart-only case not reproduced; owner will
    export diagnostics next time it happens. Two smaller iOS song issues
    remain listed on the issue.
  - I42 #528 iOS speed/pitch quality: cause confirmed on metrics; owner
    confirmed Pitch Lock was on. **Ready for an Opus build plan.**
  - I45 #526 first-push ~445 ms position step: Opus hypothesis (position
    clock stamped early on the first song); Flash probe ready, not run.
  - I43 #529 Dynamic Island: 1.6 (lock screen works; presentation only).
  - I44 #530 Siri: 1.6, design gate.

## Owner actions

- I5 TestFlight device-pass results with the 479d/e pitch checks.
- Does the macOS boost (I39) ship in 1.5.2 (needs `release/1.5` on dev's
  macOS libmpv pin)?
- I26: a device check by ear, or grant T3 Code "System Audio Recording Only"
  for a capture.
- #529: confirm the island stays empty with Navis in the background.
- #527: export diagnostics right after the next restart-only break.
- #528: listen to the measurement WAVs (`build/i528/20261110T153617Z/out/`,
  `music_locked1.25_*`) if wanted; metrics already confirm.

## Next steps

1. PR for this hand-off: Flash docs review, admin squash-merge.
2. I42 #528: Opus build plan from `build/i528/20261110T153617Z/README.md`
   §4 (Varispeed when Pitch Lock is on, tap pitch 0, EQ bands scaled by
   1/speed, queued items and crossfade deck, no algorithm flapping between
   `setSpeed`/`setPitch`); consider a Fable plan check (exception 3). Then a
   Sonnet build (bounded brief), fresh Sonnet review, Flash runtime/measure
   pass, device glitch check owed.
3. I45 #526: Flash runs `build/i526/20261110T161902Z/run_i526_ios.sh` per
   its README; if confirmed, Opus fix plan (native re-stamp when the first
   song's clock starts; not `checkForDiscontinuity`).
4. I41 #527 follow-ups once diagnostics arrive.

## Worktrees and branches

- Ours: none left except `docs/handoff-2026-11-10d` (this PR). I26, #527
  fix and investigation worktrees and branches are removed (local, GitHub,
  Forgejo mirror).
- Evidence (gitignored, this Mac only): `build/i26-ios/`, `build/i527/`,
  `build/i527-fix/` (`run_fix.sh` + `drive_fix.py` reusable radio
  fault-injection pass), `build/i528/`, `build/i526/`.
- Older T3 worktrees from earlier coordinators remain (`t3-1187c7d6`,
  `t3-2409cd4e`, `t3-45692a45`, `t3-5cc396e7`, `t3-b723854b`, `t3-fee050b4`).

## Notes learned

- `origin` pushes to GitHub and the Forgejo mirror; `--force-with-lease`
  fails on the mirror (lease ref is GitHub's). Push the mirror separately or
  delete merged branches there by URL.
- Fixing a review finding by changing object identity to value equality can
  wake stale timers: re-check found it (#539); cancel timers at the new
  intent rather than guarding on the transport generation, which `play()`
  also bumps.
