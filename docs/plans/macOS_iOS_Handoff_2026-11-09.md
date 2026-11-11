# macOS/iOS coordinator hand-off, 2026-11-09

Replaces [the 2026-11-08c hand-off](macOS_iOS_Handoff_2026-11-08c.md) as the
starting point. Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (I27 to I30
updated today). Rolled over because I27 took three review and fix rounds.

## State

- **Merged today:** #409 (ledger nits; iOS 1.5.2 ships from `dev`), #412 and
  #417 (I27 plan and ledger), #416 (I27 round 1, `release/1.5`), #431 (I27
  round 2, `release/1.5`, `9be1c045`), #438 (one foldables entry in the 1.5.2
  changelog, `release/1.5`, `53183134`).
- **#416 is on `dev`** through the other machine's #427.
- **#431 and #438 are not on `dev` yet.** The other machine's forward #437
  (`merge/i436-dev`) was open and does not include them. After #437 merges,
  open "Merge release/1.5 into dev (forward #431, #438)" with a merge commit
  (as #404 did). A trial merge of `release/1.5` into `dev` had no conflicts.
- **#392 (ReplayGain at the sample boundary)** belongs to the other machine.
  Phases 2, 3 and 5 are merged; an Android opus join fault is being worked
  there. I26 (iOS phase 4) is still blocked on it.

## Owner decisions (2026-11-09)

- iOS 1.5.2 ships from `dev`.
- I27 defects all ship in 1.5.2.
- Owner reference images (local copies in `build/foldables-i27/owner-refs/`):
  idea 1 (folded landscape, compact mini-player Now Playing) is **I28 in
  1.5.2**; idea 3 (folded portrait, navigation in the right-hand strip) is
  **I29 in 1.5.2**; idea 2 (big full-screen Now Playing when unfolded) is
  **I30 in 1.6**.
- No in-app volume slider in the I28 landscape Now Playing.
- I28 on the folded cover turned sideways: Now Playing opens full screen in
  the car layout with no navigation; browsing uses the existing compact icon
  rail.
- **Reuse, don't rebuild (owner):** no new screens or parallel layouts for
  one device. I28 reuses the compact wide shell and landscape Now Playing;
  I29 reuses the compact rail and the bottom-nav layout. No line-count
  target; reviewers reject duplicated layout code or device-specific
  branches where a size/inset rule works.

## Next steps

1. `git fetch`, check open PRs (two machines). Open the dev forward once #437
   is in.
2. **I28** from [the plan](I28_I29_Duo_Layouts_Plan.md): Sonnet `high`
   builder in a worktree off `release/1.5`, fresh Sonnet `high` review, CI,
   runtime pass on the Duo (rotated cover) and a small phone in landscape.
3. **I29** after I28 merges. Step 0 is the tap check inside the strip. If taps
   don't reach Flutter, ask the owner the plan's Q2 (pill inside the page, or
   keep the bottom bar).
4. Still waiting on the owner: I5 device-pass results from TestFlight 1.5.2
   (37437428).
5. Follow-ups on #410: iPad portrait Now Playing art sizing, the 844x390 6 px
   overflow (I28 fixes it), unfolded portrait 669x951 unverified, the
   `&amp;` album title (data decoding), Android `backwardJump` at stream start, and the folded album page's Play
   and Shuffle row starting at 4 pt while the text starts at 16 pt (phone
   inset kept on purpose in #431; owner call if it should align).

## Running the Duo simulator (learned today)

- iPhone Duo UDID `A9066D51-4474-4E29-B291-AF00A7765266` (iOS 27.2). DeviceHub
  crashes on launch; fold with the T3 `agent-device` command from
  `device_open` (`fold closed` / `fold open`, reports "unverified" but works;
  wait about 10 s before a screenshot).
- Screenshots: `xcrun simctl io <udid> screenshot --display=1` folded,
  `--display=3` unfolded. Folded 466x678 pt (84 pt right strip), unfolded
  951x669 pt.
- Builds from `release/1.5` lack the iOS-simulator diagnostics gate from
  `dev` (#322): apply `build/foldables-i27/duo-r2/ios-gate-cherry-pick.patch`
  and restore `lib/src/utils/diagnostics_build_gate.dart` from `97c5ce94a` in
  a scratch worktree. Launch scripts are in the old session scratchpad
  (`*-r3.sh`); copy them into the item's evidence folder if needed.
- Evidence: `build/foldables-i27/duo/` (before), `duo-r2/`, `duo-final/`,
  `duo-final2/` (merged code, all fixes confirmed, clean log).

## Worktrees and branches

No live workers. All I27 branches and worktrees are deleted. This hand-off's
branch is `docs/handoff-2026-11-09`.
