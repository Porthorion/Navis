# macOS/iOS coordinator hand-off (2026-11-07)

Rollover after three item PRs merged and one test build published (owner rule,
2026-11-07, in `~/.claude/CLAUDE.md` "Context"). Supersedes
[macOS_Handoff_2026-11-06.md](macOS_Handoff_2026-11-06.md).

## State

- dev = `334a07a6` (origin). Main checkout `~/Documents/forgejo_projects/Navis` on dev, clean.
- macOS parity: every item M0–M13 merged ([macOS_Parity_Plan.md](macOS_Parity_Plan.md)).
  M13 merged as #308 (`7bbd1d5a`), owner-confirmed; changelog lines for M2–M5, M9, M11
  added (#312, `fbf01ee8`) in the 1.5.2 block (owner: 1.5.2 is the first macOS/iOS
  release, so they stay there).
- iOS: plan and inventory merged (#320, `334a07a6`), triage approved by the owner
  ([iOS_Parity_Plan.md](iOS_Parity_Plan.md)). Owner decisions: TestFlight/App Store;
  simulator-first testing, the iPhone is borrowed (give notice, use only when needed);
  CarPlay open (owner asked what it takes; answer is the plan's CarPlay note; add it as
  I9 only if the owner says so).
- Ledger for macOS: Porthorion/Navis#209. iOS ledger: the iOS plan file (update its rows).

## In flight

- **PR #322** `feat(ios): diagnostics API in iOS simulator debug builds` (I0), branch
  `feat/ios-i0-sim-diagnostics`, commit `217d402d`, worktree
  `.claude/worktrees/agent-a6a1b0775124536d1` (Sonnet build). Runtime proof done
  (iPhone 17 simulator, `/v1/health` ok with token, 401 without; logs
  `~/.cache/claude-navis-logs/ios-i0-*`). Needs:
  1. **Opus decision first:** the build added `if (kDebugMode) rootContainer.read(appRouterProvider)`
     in `lib/main.dart` to dodge a Riverpod debug assertion (providers publishing state
     while mounting inside `NavisApp.build`). Check whether it is scoped to the iOS
     diagnostics clone or runs in every debug build on every platform; it should not
     change non-iOS debug startup. Decide: scope it to the clone, or fix the race at the
     source as its own item (reachability and library-sync controllers listening to
     `serverConfigStateProvider`). Sonnet diagnosed it; Opus must confirm the cause.
  2. A fresh Sonnet `high` review (diagnostics API = security-relevant: release and
     on-device builds must stay off; check the gate folds to false in release).
  3. CI, then squash-merge, update the I0 row in the iOS plan.
- Simulator iPhone 17 (`CE8EF4B8-D441-4991-8F0F-DFA4BE4741AE`) left booted; it is
  fine to reuse.
- Nothing else running. Sub-agents: none.

## Next steps

1. #322 as above.
2. I1 (playback runtime pass on the simulator) with I2 (local network) and I3
   (keychain options) alongside; I4 and I6 as small parallel PRs. Opus plans each risky
   item before a Sonnet build.
3. Cold simulator debug builds take about 7 minutes; the launcher's 600 s poll is tight.

## Owner actions

- Paid Apple Developer Program (TestFlight/App Store, notarized macOS, CarPlay request).
- Apple Development certificate: done 2026-11-07 (Team ID `BFBNSCVKXH`; WWDR G3
  intermediate installed). Sign owner test builds with
  `"Apple Development: khalifaalzarouni@hotmail.com (DVVR8LDA3B)"`.
- macOS hands-on pass (playbook section 6) and notarize credentials.
- Not ours: #266 (downloads folder) and the desktop media-info dialog belong to the
  1.5.2 session.
