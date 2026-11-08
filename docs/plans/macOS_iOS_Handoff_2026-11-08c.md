# macOS/iOS coordinator hand-off, 2026-11-08c

Previous: [2026-11-08b](macOS_iOS_Handoff_2026-11-08b.md) (read it for the I5
device-check list and the I21/I24/I25 known limits). Ledger:
[iOS_Parity_Plan.md](iOS_Parity_Plan.md).

## State

- `dev` = `c44330aa`. Merged on 2026-11-08: I23 (#381), I21 pitch (#399),
  I25 EQ per format (#401), I24 ReplayGain boost (#403).
- TestFlight 1.5.2 (37437428) from `65cddcf6` is processed (VALID). The
  owner adds it to the internal group; it is the I5 device pass build.
  macOS dev app 1.5.2 (10502) installed at `~/Applications/Navis.app`,
  Apple Development signed.
- The 2026-11-08c coordinator settled after the builds without launching a
  successor; this hand-off replaces that gap.

## Open work, in order

1. **I5 device pass** (owner, borrowed iPhone, TestFlight 37437428): checks
   listed in the 08b hand-off. When the owner reports results, triage each
   failure (Opus root cause, Sonnet fix) and add ledger rows.
2. **dev → release path for iOS (owner question).** `origin/dev` has ~270
   commits not on `release/1.5`, many of them iOS. 1.5.2 desktop/Android
   ships from `release/1.5`; iOS 1.5.2 (TestFlight/App Store) currently
   ships from `dev`. Ask the owner once whether iOS 1.5.2 ships from `dev`
   (status quo) or whether iOS commits must be back-ported to
   `release/1.5`, and record the answer in the ledger.
3. **ReplayGain at the sample boundary (#392)**, led by the other machine
   (phase 1 Dart contract merged in #402). Its phase 4 is iOS and waits on
   owner decision D4. Do not start it until the issue says D4 is decided
   and phases 1–3 have landed; then plan it against the shared I23 tap
   (every queued item already has the tap before preroll since I23, which
   answers the issue's caveat at its line 212).
4. **Ledger nits:** CarPlay 2.0.0 in `development-plan.md` vs 1.6 in newer
   docs; Mac App Store updater gating plus App Sandbox as a future macOS
   item.
5. **Demo server:** a separate Opus coordinator the owner starts. If it asks,
   check that Navis keeps a base-URL path (`/demo`) on every request.

## Rules for this lane

- Don't settle while owner-dependent work is open; stay idle in the thread
  and say what you are waiting for. Roll over only per `~/.claude/CLAUDE.md`
  (count events), and always launch the successor in the same turn.
- Git fetch and check open PRs before planning or merging (two machines).
