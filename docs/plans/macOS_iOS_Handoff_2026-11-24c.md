# macOS/iOS coordinator hand-off, 2026-11-24 (third)

Previous: [macOS_iOS_Handoff_2026-11-24b.md](macOS_iOS_Handoff_2026-11-24b.md).
Tablet ledger and spec: [tablet-ux-plan.md](tablet-ux-plan.md).

**Why the rollover:** three item PRs merged this round (#808, #809, #810).

## State

- `release/1.5` is at `96b766aa0` (#810), plus this hand-off's docs commit.
- The main checkout is clean on `dev`.
- Merged this round, all to `release/1.5`, each with a fresh Sonnet review and green CI:
  - #808 P2.4: `ContentLayout.readingWidth` (720) caps the lyric column and the artist bio.
  - #809 P2.2: touch panes >= 720 get a denser Home: the compact-wide header row, flat sections and two-column song lists. The gate is text-scaled and excludes phone form factors. Review fixes were re-checked.
  - #810 P2.6: the Downloads body caps at 1040, and the EQ wide layout opens from a 760 pane.
- **Open: #812 P2.3** (Playlists tab cover grid from a 600 pane), branch `tablet/p2.3-playlists-grid`, worktree `../Navis-p2.3`, head `8266b2b2e`.
  - Review done: one blocking finding (the desktop More button) fixed in `d58f1a6b5`, and a re-check found nothing blocking.
  - CI was running at rollover. Next step: when CI is green, unlink the PR, squash-merge, then delete the worktree and branch.
  - One possibly flaky test: "a device playlist created offline appears under Your playlists" in `library_screen_test.dart`. It failed 2 of 7 local runs (pending 5 s secure-storage timer from `_listenBrainzDiscoverStream`). If CI hits it, re-run once. If it recurs, have Opus look at the timer.
- No worker threads, delegates or PR watches are live.
- These PRs need forwarding to `dev`; the Linux coordinator usually does it. Overlap check: #808-#812.
- Owner rules are unchanged:
  - Reorganize existing widgets only; redesign waits for 1.6.
  - Gate on pane width, never on platform.
  - The work covers every tablet and medium-width form factor.

## Decisions taken this round (owner may veto)

- **P2.3:** no playlist card existed, so `AlbumCardContent` gained an optional `artwork` slot filled with the existing playlist artwork widgets. The card is unchanged when the slot is null. The owner was told and can defer the grid to 1.6 instead.
- **P2.2:** on wide panes Instant Radio moves to the header row's icon button with a tooltip, instead of the large mobile button.
- **P2.6:** the plan expected the EQ presets panel on 13" portrait. The panel needs desktop >= 1200, so 13" portrait gets the side-by-side graph and inspector instead. Desktop windows above 1040 also get the Downloads cap.

## Lessons

- **Run builders in the foreground or through `delegate_task`.** T3 says background work goes through `delegate_task`, not a background Agent.
- **Unlink before merging.** A merge watch links the PR, and merging a linked PR settles the coordinator thread. Unwatch and unlink first, then merge with `gh pr merge --squash --match-head-commit`.
- **Default test viewport.** The default test surface (800x600) now counts as wide for Home and the Playlists tab. Older tests that meant phone or list layout pin 390x844 or 599 wide.
- **Rebase stacked branches before diffing.** A branch built while others merge shows their changes reversed in `git diff origin/release/1.5..HEAD`. Rebase before review.

## Next steps

1. Merge #812 (above).
2. One batched runtime pass, run by Flash on the iPad Pro 13" simulator with an Opus-written script, on `release/1.5` after #812. Cover:
   - 13" portrait and landscape: Home, Library > Playlists, the lyrics route, an artist with a bio, EQ, Downloads;
   - mini portrait (756, bottom nav): Home;
   - iPhone portrait: Home and Playlists unchanged.
   The macOS 1440x900 checks for Downloads, Playlists and lyrics can come from a dev build later.
3. After that, resume the iPad 13" App Store screenshot set. It was blocked only on P2.2.
4. P2.5, the queue side panel (medium risk): Opus plan, then Sonnet build, fresh Sonnet review, CI.
5. #805: the marquee in the collapsed rail Now Playing ticks off screen (`app_shell.dart` `TickerMode`). Small, but `app_shell.dart` is a hot file, so do it one at a time.
6. #811: the EQ header overflows 19 px at a 700 touch pane. Small, not tablet-plan scope.
7. P3 items if time allows (P3.3 needs a Drift migration and is risky).

## Simulators

- iPad Pro 13" `F9F6467B-3FDF-4F46-847C-BCE59102778C`: signed in to `https://sub.porthorion.com` as `navis`, on the old `a5c9897ff` debug build. Rebuild from `release/1.5` for the pass.
- iPad mini: `61DF7A41-2340-42A3-9A7C-13004A6FB01E`.

## Other open items and owner actions

Unchanged from the [previous hand-off](macOS_iOS_Handoff_2026-11-24b.md#other-open-items-unchanged-from-the-previous-hand-off): the App Store listing "demo server" wording, I41b PR #564, the demo account, the privacy policy, ASC 1.5.2, the password rotation, the Keychain prompt report, and no tag or release without the owner.

## Worktrees

- `Navis-p2.3`: the open #812. Delete it after merge.
- `Navis-handoff`: this docs PR. Delete it after merge.
- Untouched, belonging to others: the `.t3/worktrees` checkouts, `Navis-glow`, `Navis-mac152`.
- Deleted this round: `Navis-p2.2`, `Navis-p2.4`, `Navis-p2.6` and their branches.
