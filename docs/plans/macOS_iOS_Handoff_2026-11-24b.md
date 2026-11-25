# macOS/iOS coordinator hand-off, 2026-11-24 (second)

Previous: [macOS_iOS_Handoff_2026-11-24.md](macOS_iOS_Handoff_2026-11-24.md).
Tablet ledger and spec: [tablet-ux-plan.md](tablet-ux-plan.md).

**Why the rollover:** three item PRs merged this round (#802, #804, #806).

## State

- `release/1.5` is at `a5c9897ff` (#806), plus this hand-off's docs commit.
- The main checkout is clean on `dev`.
- No worker threads, delegates or PR watches are live.
- Merged this round, all to `release/1.5`, each with a fresh Sonnet review, a re-check of fixes, and green CI:
  - #802 P1.1: the tablet rail player moved into the phone `_MiniPlayerStrip` at the bottom of the content pane, and `_RailMiniPlayer` was deleted.
  - #804 P0.3 / issue #803 (closed): embedded Now Playing on touch rail panes gets the collapse button and swipe-down.
  - #806 P1.2: the tablet rail follows the navbar-style setting (220 / 260 / 64), shown on tablets as "Sidebar". Icons-style tiles get tooltips and semantics labels.
- Runtime passes on the iPad Pro 13" simulator are all green:
  - `build/ipad-ux/p1.1/runtime/`
  - `build/ipad-ux/batch-p12-803/` (P1.2 and #803 on merged `release/1.5`)
- These PRs need forwarding to `dev`; the Linux coordinator usually does it. Overlap check: #801-#806.
- Owner rules for the tablet work are unchanged:
  - Reorganize existing widgets only; redesign waits for 1.6.
  - Gate on pane width or shell, never on platform.
  - The work covers every tablet and medium-width form factor.

## Lessons for the next items

- **Goldens are rendered on Linux only.** `test/flutter_test_config.dart` skips golden comparison on other hosts, so a local macOS pass proves nothing about goldens. Avoid changing text or visuals on golden-covered screens; #806 kept the desktop heading for this reason. If a golden must change, the Linux machine regenerates it.
- **CI runs tests the briefs did not list.** Two CI failures came from tests outside the focused set:
  - the design-token baseline, after code was deleted (fix: `NAVIS_UPDATE_TOKEN_BASELINE=1`, lower it only);
  - `now_playing_info_chip_gestures_test` (an ambiguous `find.byTooltip('Close')`).
  
  Briefs should say: `rg -l` the touched widgets and l10n keys across `test/` and run those files too.
- **One flaky test:** `navis_audio_handler_navigation_queue_test` "first-byte allowance (#685) Next onto a new cold song" failed once on #806 and passed on re-run.
- **`Fixes #N` in a PR to `release/1.5` does not auto-close the issue,** because it is not the default branch. Close it by hand.

## Tablet items (ledger: tablet-ux-plan.md)

| Item | State |
|---|---|
| P0.1, P2.0, P2.1 | merged (#799, #800) |
| P0.3 #803 | merged #804 |
| P1.1 | merged #802 |
| P1.2 | merged #806 |
| **P2.2 Home density** | **next** (low risk, `home_screen.dart`). Plan section 5. |
| P2.3 / P2.4 / P2.6 | then, low risk, can run in parallel (different files) |
| P2.5 queue side panel | after; medium risk |
| P3 | 1.5.x if time allows. P3.3 needs a Drift migration (risky). |
| #805 | collapsed rail Now Playing marquee ticks off screen; small, low priority (`app_shell.dart` `TickerMode`) |
| #798 F16 playlist "No songs" flash | not tablet-specific |

Runtime-pass notes to check later:
- In landscape, a row can sit half under the strip mid-scroll, which is normal. The end of a list clears the strip (P1.1 test and runtime 05).
- The icon tooltip bubble overlaps the neighbouring icon. This is the existing `NavisTooltip` placement.

**Simulators:**
- iPad Pro 13" `F9F6467B-3FDF-4F46-847C-BCE59102778C` is booted, signed in to `https://sub.porthorion.com` as `navis`, on the `release/1.5` debug build from `a5c9897ff`. The device session is released and the sidebar style is set to Default.
- iPad mini: `61DF7A41-2340-42A3-9A7C-13004A6FB01E`.

## Other open items (unchanged from the previous hand-off)

- App Store screenshots: the iPad 13" set was on hold until P1.1, P1.2 and P2.2 land. P1.1 and P1.2 have landed, so the set waits only on P2.2.
- `docs/release/app-store-listing.md` ~line 90: change "demo server" to the live server.
- I41b, PR #564, is still open.
- Later: #530 to 1.5.3, Siri in 1.5.3, and the README's iOS status is stale.

## Owner actions (unchanged)

- Set up `demo/demo` on `navis.porthorion.com/demo`, then the coordinator verifies it.
- Fix the privacy policy page so it covers iOS and macOS.
- Create ASC version 1.5.2 with build 38709648.
- Rotate the server password.
- Report on the Keychain prompt.
- Do not tag or release 1.5.2 without the owner.

## Worktrees not from this round

These are untouched; leave them to their owners or check them before deleting:
- the `.t3/worktrees` foldable and survey checkouts
- `Navis-glow`
- `Navis-mac152`

This round's worktrees (`Navis-p1.1`, `Navis-np803`, `Navis-p1.2`, `Navis-rt15`) and branches are deleted. `Navis-handoff` holds this docs PR and can be deleted after it merges.
