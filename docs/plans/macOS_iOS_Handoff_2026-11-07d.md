# macOS/iOS coordinator hand-off (2026-11-07, fourth)

Rollover after three review/fix rounds on PR #350 (owner rule in
`~/.claude/CLAUDE.md` "Context"). Supersedes
[macOS_iOS_Handoff_2026-11-07c.md](macOS_iOS_Handoff_2026-11-07c.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (update its rows).

## State

- dev = `eee9daa2` before this hand-off PR. Merged this session:
  - #346 (`cee70d8e`): owner scope decision from I11, recorded in the ledger
    ("Scope decision from I11"): 1.5.2 brings iOS to Android parity (I9, I18,
    I4 with I14, release items I2, I5–I8); new features land in 1.6 on every
    platform (I13 sleep timer, I12 as a cross-platform output-device button,
    I15 sharing, I17 widgets for Android and iOS together); CarPlay (I20), Siri
    (I16) and background sync (I19) in 1.6 for iOS.
  - #347 (`487ac78d`): keychain `first_unlock_this_device` (owner delegated the
    choice; matches Android's no-backup policy). Sonnet + Opus reviews, nothing
    blocking. I5 gained a check: a second sign-in over an existing keychain
    item on hardware.
  - #348 (`eee9daa2`): I6, CocoaPods removed, dark-only launch screen (the
    default app theme is dark), `ITSAppUsesNonExemptEncryption`, privacy
    manifest. Flash review nothing blocking.
- I10 transport slot verified on the simulator (EQ button shows and opens).
- The main checkout still has git-ignored `ios/Pods/` and `ios/Podfile.lock`
  leftovers from before I6; harmless, delete them if a build complains.

## In flight

- **PR #350, I4 + I14** (`feat/i4-ios-downloads-files`, head `17dc6524`,
  builder worktree `.claude/worktrees/agent-a55df5d382acdd0f4`): iOS database
  moves Documents → Application Support (shared desktop migration), downloads
  root `Documents/Downloads` visible in Files, backup exclusion for downloads
  and the permanent artwork store, picker hidden, container-path rebase in
  `NavisDatabase.beforeOpen` (iOS changes the container UUID on every update;
  stored absolute paths were never rebased: pre-existing, would have lost all
  downloads), failed-rebase guard on the destructive startup passes.
  Reviews: Sonnet (round 1, nothing blocking), Opus ×3 (round 1: container
  blocker; round 2: stale-WAL adoption; round 3: adoption still unsafe and the
  guard read its flag before open). Round 3 fix removed sidecar adoption
  entirely and made the guards open the database first.
  **Next:** a fresh Opus re-check of `475d638f..17dc6524` (requirements:
  no stale sidecar ever paired with a newer main; failed rebase never prunes
  or deletes on that launch, guard holds when a prune is the first query;
  healthy launches unchanged on every platform), then CI green, then
  squash-merge, delete the branch and worktree. Simulator reinstall proof
  (container UUID change, download still `kind=file`, no duplicate) is in the
  PR body. Known follow-ups listed in the PR body (failed-rebase retry of
  finished journals, copy fallback writing straight to final paths).
- No other PRs, subagents, delegates or worker threads.

## Next steps

1. Finish #350 as above.
2. I2 (local network prompt; LAN-IP and https servers), then I18
   (accessibility pass, shared widgets) as the remaining 1.5.2 iOS items;
   I8 docs/CI last; I7 needs the paid programme.
3. Small findings to triage (unchanged): `tool/sync_diagnostics.sh` pre-run DB
   summary crashes on the macOS database (`no such table:
   song_identity_aliases`); two `ping.view` errors at startup; end-of-sync
   state `partial`. Check whether diagnostics scripts locate the iOS database
   in Application Support after #350.
4. I9 follow-ups from PR #335 (none blocks release).
5. I5 device pass (ask the owner with notice; borrowed iPhone): I9 checks,
   lock screen, and the keychain second sign-in.

## Owner actions and questions

- Ask with the next batch: a downloaded file deleted in the Files app is
  dropped from downloads at the next launch, not re-downloaded (documented
  behaviour). Keep, or re-download?
- Unchanged: paid Apple Developer Program; macOS hands-on pass; #266 and the
  desktop media-info dialog belong to the 1.5.2 session.
