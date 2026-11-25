# macOS/iOS coordinator hand-off, 2026-11-24

Previous: [macOS_iOS_Handoff_2026-11-11.md](macOS_iOS_Handoff_2026-11-11.md).
Tablet ledger and spec: [tablet-ux-plan.md](tablet-ux-plan.md).

**Why the rollover:** three item PRs merged this round (#797, #799, #800).

## State

- `release/1.5` is at `6116aaff0` (#800).
- The main checkout is clean on `dev`.
- No worker threads or delegates are running.
- Merged this round, all to `release/1.5`:
  - #796: DMG concept A, volume "Install Navis".
  - #797: tablet UX plan (docs; admin-merged because docs skip `ci`).
  - #799: P0.1, lyrics toggle in the embedded Now Playing.
  - #800: P2.0 + P2.1, `ContentLayout.wideDetail`, the album/playlist header row on wide touch panes, and the album filter reachable across 720.
- These need forwarding to `dev`. The Linux coordinator usually does it. Overlap check: #791, #793-#800.
- Owner rules for the tablet work:
  - Reorganize existing widgets only. Redesign waits for 1.6 (plan section 9).
  - The tablet work covers every tablet and medium-width form factor (iPad, Android tablets and foldables, desktop windows). Gate on pane width, never on platform.

## Tablet items (ledger: tablet-ux-plan.md)

| Item | State |
|---|---|
| P0.1 embedded lyrics toggle | merged in #799 |
| P0.2 Download Album | not reproduced. Two modals (quality, then "Always use?") must both complete; evidence in `build/ipad-ux/p0-download/`. The extra decisions are a UX note for 1.6. |
| P2.0 `wideDetail` gate | merged in #800 |
| P2.1 album/playlist header row | merged in #800. The desktop 900 check is kept on purpose (plan updated). |
| **P1.1 bottom player strip in the rail shell** | **next.** Risky (hot file `app_shell.dart`), so it needs a Sonnet build, a Sonnet review and a runtime pass. |
| P1.2 navbar-style setting on tablets | after P1.1, one at a time (hot file) |
| P2.2, P2.3/P2.4/P2.6, P2.5 | in the plan order after P1.2 |
| P3 | 1.5.x if time allows. P3.3 needs a Drift migration (risky). |
| F16 playlist "No songs" flash | issue #798, not tablet-specific |

**Simulators:**
- iPad Pro 13" `F9F6467B-3FDF-4F46-847C-BCE59102778C` is booted and signed in to the live server, with scrobbling off and the device session released.
- iPad mini: `61DF7A41-2340-42A3-9A7C-13004A6FB01E`.
- Runtime passes use `https://sub.porthorion.com` with the disposable `navis` account (password file `build/ios-diagnostics/password.txt`). `navis.porthorion.com/demo` is the future App Review demo account and is not set up yet.

## Other open items

- **App Store screenshots** (`build/appstore-screenshots/`):
  - The iPhone 6.9" set of 8 is done. Small flaws: the Library top row sits under the search bar, and the last row is cut off by the mini player on Album and Downloads.
  - The iPad 13" set is **on hold** until P1.1, P1.2 and P2.2 land. 07-downloads is missing; 01 and 04 have titles caught mid-scroll.
- **`docs/release/app-store-listing.md` ~line 90:** change "demo server" to the live server (small docs PR).
- **I41b, PR #564:** carried over from 11-11 and still open. See the previous hand-off.
- **Later:** #530 to the 1.5.3 milestone; Siri planned for 1.5.3; the README iOS status is stale.

## Owner actions

- Set up `demo/demo` on `navis.porthorion.com/demo`, then the coordinator verifies it.
- Fix the privacy policy page so it covers iOS and macOS.
- Create ASC version 1.5.2 with build 38709648.
- Rotate the server password: an earlier agent's screenshot showed it unmasked in its tool output.
- Report on the Keychain prompt.
- Do not tag or release 1.5.2 without the owner.

## Worktrees not from this round

Leave these to their owners or check them before deleting:
- the `.t3/worktrees` foldable and survey checkouts
- `Navis-glow` (`fix/home-showcase-glow`)
- `Navis-mac152` (`local/mac152-signed`, the signed 1.5.2 DMG build)
