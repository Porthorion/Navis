# macOS/iOS coordinator hand-off, 2026-11-25

Previous: [macOS_iOS_Handoff_2026-11-24c.md](macOS_iOS_Handoff_2026-11-24c.md) (its Lessons and those of
[2026-11-24b](macOS_iOS_Handoff_2026-11-24b.md) still apply).
Tablet ledger and spec: [tablet-ux-plan.md](tablet-ux-plan.md).

**Why the rollover:** item PRs #812, #814, #815 and #816 merged this round.

## State

- `release/1.5` is at `9cd8e607f` (#816), plus this hand-off's docs commit.
- The main checkout is clean on `dev`.
- Merged this round to `release/1.5`, each with a fresh Sonnet review and green CI:
  - #812 P2.3: the Playlists tab is a cover grid from a 600 pane.
  - #814 P2.5: rail panes >= 600 open the queue as the desktop floating panel. A review-round fix keeps the gesture
    flags sane across a rotation mid-reorder and keeps Now Playing's tickers on behind the panel. A re-check found
    nothing blocking.
  - #815 (#805): the collapsed rail Now Playing stops its tickers.
  - #816 (#811): the roomy EQ graph toolbar is chosen by text scale. The issue's "19 px at 1.0x" was an Ahem
    test-font artifact; the real overflow was at 1.3x and up.
  - #813: the previous hand-off (docs, admin-merged because docs-only PRs skip the required `ci` check, as #807 was).
- Close #805 and #811 by hand if still open (`Fixes #N` to `release/1.5` does not auto-close).
- No worker threads, delegates or PR watches are live. No PR is linked to the coordinator thread.
- These PRs need forwarding to `dev` (the Linux coordinator usually does it): #812-#816.
- P0, P1 and P2 of the tablet plan are done. Remaining: P3 (section 6 of the ledger).

## Runtime and screenshots

- Batched iPad pass after P2.2-P2.6: all pass (ledger, "Batched runtime pass"). Evidence `build/ipad-ux/batch-p2/`.
- iPad 13" App Store set retaken on the new layout, all 8 at 2064x2752: `build/appstore-screenshots/ipad-13/`
  (old set in `ipad-13-old/`). The iPhone 6.9" set was complete already. Notes: `build/appstore-screenshots/NOTES.md`.
  Settings on the 13" simulator were restored; scrobbling stays OFF.

## Owner question (ask once, with the next question batch)

The App Store screenshots (both sets) were taken against `sub.porthorion.com` and show commercial album art (A$AP
Rocky, BLACKPINK, game soundtracks) and copyrighted lyrics. App Review can reject screenshots with third-party content
the developer has no rights to (guideline 5.2.2). Options: keep them; or retake against a library of licensed,
royalty-free music (the planned demo server). The listing doc now says "live server" as the previous hand-off asked.

## Lessons

- **A booted simulator is a heavy job.** The first runtime pass ran beside a builder's `flutter test`: load 226, swap
  8.3/9.2 GB, and the agent-device XCTest runner never started. Device passes now check `pgrep -x flutter_tester`,
  `pgrep -x dartaotruntime` and load before booting and stop if busy. Never schedule a device pass while a builder or
  reviewer may run tests.
- **Check a runtime "FAIL" against the screenshot.** Both FAILs in the second pass were not bugs: a tap 40 pt off the
  icon, and the split Now Playing's own queue column.
- **Overflow repros need the real font.** flutter_test's default Ahem font is far wider than Inter; layout thresholds
  measured with Ahem are wrong. Load Inter as `now_playing_screen_adaptive_test.dart` does.
- **A native foreground `Agent` blocks the coordinator.** Run independent builders as parallel `Agent` calls in one
  message, or use `delegate_task` for background work.

## Next steps

1. This docs PR was admin-merged by the outgoing coordinator; delete `../Navis-handoff` and branch `docs/handoff-2026-11-25` if still present.
2. P3 items, Opus plan each first:
   - P3.1 pointer affordances by policy (low risk, S).
   - P3.2 hardware keyboard shortcuts on tablets (low-medium, S-M).
   - P3.3 the 600-839 tier setting: needs a Drift migration, risky, full lifecycle with an Opus review.
3. Runtime for P3 items: batch them into one pass at the end (iPad with a hardware keyboard/trackpad where possible).
4. macOS 1440x900 checks for Downloads, Playlists, lyrics and the queue from a dev build after the forwards.

## Simulators

- iPad Pro 13" `F9F6467B-3FDF-4F46-847C-BCE59102778C`: signed in as `navis` on `https://sub.porthorion.com`, debug build
  of `107f3ca45`.
- iPad mini `61DF7A41-2340-42A3-9A7C-13004A6FB01E` and iPhone 17 `CE8EF4B8-D441-4991-8F0F-DFA4BE4741AE`: same build.

## Other open items and owner actions

Unchanged from the [2026-11-24b hand-off](macOS_iOS_Handoff_2026-11-24b.md#owner-actions-unchanged), except that the
listing "demo server" wording is done: I41b PR #564, the demo account, the privacy policy, ASC 1.5.2, the password
rotation, the Keychain prompt report, and no tag or release without the owner.

## Worktrees

- `Navis-handoff`: this docs PR, merged; delete it and its branch if still present.
- Untouched, belonging to others: the `.t3/worktrees` checkouts, `Navis-glow`, `Navis-mac152`.
- Deleted this round: `Navis-p2.3`, `Navis-p2.5`, `Navis-i805`, `Navis-i811`, the previous `Navis-handoff`, and their
  branches.
