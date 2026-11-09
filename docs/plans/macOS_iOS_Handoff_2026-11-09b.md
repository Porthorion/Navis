# macOS/iOS coordinator hand-off, 2026-11-09 (b)

Replaces [the 2026-11-09 hand-off](macOS_iOS_Handoff_2026-11-09.md). Ledger:
[iOS_Parity_Plan.md](iOS_Parity_Plan.md) (I28, I29, I31 updated). Rolled over
after three item PRs merged (#443, #445, #449).

## State

- **Merged today on `release/1.5`, all forwarded to `dev`:** #443 I28 (short
  landscape phones use the compact wide shell, `93b16f0b`, forward #444), #445
  I29 (navigation pill in the folded Duo cover's side strip, `a72aa135`,
  forward #446), #449 I31 follow-ups F1-F4 (`af6d60b6`, forwarded in the PR
  that carries this hand-off). Docs: #441, forward #442.
- The planned 1.5.2 foldables work (I27 to I29) is done.
- Open PRs not ours: #414 (1.6 live-mode design, other machine).
- #392 (ReplayGain, other machine) and I26 are unchanged.

## Owner actions

- I5 device-pass results from TestFlight 1.5.2 (37437428): still waiting.
- Owner was offered a `dev` TestFlight build to try I28/I29 on a real device:
  no answer yet.

## Known, not planned

- The Library grids restore scroll as a pixel offset across a column-count
  change (fold/rotate), so a fold lands on a different letter; the rail now
  shows the right letter. Restore by item index would be separate work; owner
  call.
- I28 rotated Duo cover is covered by widget tests only: `agent-device` cannot
  rotate the folded cover in the simulator.
- 1.5.2 follow-ups from #410 still listed in the previous hand-off (iPad
  portrait Now Playing art, unfolded portrait 669x951, `&amp;` album title,
  Android `backwardJump`, folded album Play row inset).

## Runtime passes (learned today)

- `agent-device` has `press x y` in points (no `tap`), `type`, `keyboard enter`
  (iOS has no keyboard dismiss), `fold closed/open` (reports "unverified" or
  "hinge read returned no sample" but works; wait 12-24 s, screenshots right
  after can be black).
- Diagnostics sign-in: launch with `NAVIS_DIAGNOSTICS_USERNAME=navis` and
  `NAVIS_DIAGNOSTICS_CREDENTIAL_PATH=<main repo>/build/ios-diagnostics/password.txt`;
  do not reuse a copied profile database (the I29 pass did and got 401s; the
  account itself works, checked 2026-11-09).
- Evidence: `build/i28-runtime/`, `build/i29-step0/`, `build/i29-runtime/`,
  `build/fu-runtime/`.

## Worktrees and branches

No live workers or delegates. All item branches and worktrees are deleted.
This hand-off's branch is `merge/rel15-dev-fu` (forward PR).

## Next steps

1. Merge the forward PR carrying this hand-off (merge commit) on green CI.
2. Wait for the owner: I5 results, the `dev` TestFlight question, and whether
   to pick up the #410 follow-ups or grid item-index restore for 1.5.2.
