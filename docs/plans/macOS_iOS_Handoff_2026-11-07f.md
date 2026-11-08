# macOS/iOS coordinator hand-off (2026-11-07, sixth)

Rollover after three item PRs merged (owner rule in `~/.claude/CLAUDE.md`
"Context"). Supersedes
[macOS_iOS_Handoff_2026-11-07e.md](macOS_iOS_Handoff_2026-11-07e.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (update its rows).

## State

- dev = `5c2816b2` before this hand-off PR. Merged this session:
  - #358 (`5bec003d`): I8, iOS docs (README "iOS status", technical overview,
    [iOS testing playbook](../platforms/ios-testing-playbook.md)) and an `ios`
    CI job (`flutter build ios --simulator --debug` on `macos-latest`, part
    of the `ci` gate; green). Flash review, findings fixed.
  - #360 (`b12adafc`): failed-rebase launch holds finish-journaled downloads
    (requeue and worker), copy fallback through `.navis-part`. Sonnet + Opus
    review (one blocker, fixed), Sonnet re-review nothing blocking.
  - #359 (`5c2816b2`): diagnostics tooling (alias table, macOS DB path,
    fixture `host`). Flash review, blocker fixed.
- Small findings triage and deferred follow-ups are recorded in the ledger
  ("Small findings from the 2026-11-07e hand-off").
- Owner decisions 2026-11-07 (in the ledger): Files-app deletes are dropped at
  next launch; iPhone SE/mini keep 40 pt transport buttons for 1.5.2; the
  owner now has the **paid Apple Developer Program**.
- Incident: `git stash` is shared across worktrees; two parallel builders
  collided on it (recovered, nothing lost). Delegated prompts now forbid
  `git stash`.
- No PRs, subagents, delegates or worker threads running. The two t3
  worktrees under `~/.t3/worktrees/Navis/` are not this coordinator's.

## Remaining 1.5.2 iOS items

1. **I7** release path (TestFlight/App Store upload in `tool/release.sh`,
   App Store Connect API key, export options, privacy answers). Plan: do I7
   before I5 so the device pass runs on a TestFlight build. Blocked on the
   owner actions below.
2. **I5** device pass on the borrowed iPhone, from a TestFlight build; ask the
   owner with notice. Checklist in the iOS testing playbook.

## Owner actions and questions

Asked 2026-11-07, not yet answered:

1. Confirm enrolment finished and give the Team ID (still `BFBNSCVKXH` or a
   new team?).
2. Register the app ID `com.navis.app.navis` (or choose another bundle ID
   before the first upload; it cannot change afterwards).
3. Create the App Store Connect app record ("Navis", that bundle ID).
4. Create an App Store Connect API key (App Manager); keep the `.p8`, Key ID
   and Issuer ID on the Mac; collect them with `request_secret`, never in
   chat.

Unchanged: macOS hands-on pass; #266 and the desktop media-info dialog belong
to the 1.5.2 session.

## Next step

If the owner has answered, plan I7 (Opus; risky: release) and build it with
Sonnet. Otherwise wait for the answer; no other 1.5.2 iOS item is unblocked.
