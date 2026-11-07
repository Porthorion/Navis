# macOS/iOS coordinator hand-off (2026-11-07, fifth)

Rollover after three item PRs merged (owner rule in `~/.claude/CLAUDE.md`
"Context"). Supersedes
[macOS_iOS_Handoff_2026-11-07d.md](macOS_iOS_Handoff_2026-11-07d.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (update its rows).

## State

- dev = `a7740d09` before this hand-off PR. Merged this session:
  - #350 (`ebdbe05f`): I4 + I14, downloads in the Files app, backup
    exclusion, database out of `Documents`, container-path rebase. Final Opus
    re-check found an unguarded on-access delete (resolver and download queue
    dropped records on a failed-rebase launch); fixed test-first, Sonnet
    review nothing blocking.
  - #353 (`ec4a3442`): I2, `NSLocalNetworkUsageDescription` on iOS and macOS,
    fixture `--bind`; simulator: LAN-IP http fixture and the https server both
    stream (`kind=lockCachedStream`). No ATS change. Flash review; fixed its
    findings (changelog entry, private IP removed from the ledger).
  - #355 (`a7740d09`): I18 accessibility pass (Now Playing transport 44 pt on
    rows >= 340 dp, mini player 44 pt, settings overflow at 2x/3.1x,
    play/pause label, Reduce Motion). Two Sonnet review rounds. Five Linux
    goldens regenerated via a temporary CI job (removed before merge; goldens
    only render on Linux, `test/flutter_test_config.dart`).
- Deviation: I2's simulator evidence was lost when its worktree was removed
  with `--force` (it lived in the worktree's ignored `build/`); the key log
  lines are in the #353 description. Builders now write evidence to the main
  checkout's `build/ios-diagnostics/<item>-run/` (I18's is there).
- No PRs, subagents, delegates or worker threads running. Two t3 worktrees
  under `~/.t3/worktrees/Navis/` (`t3-5cc396e7`, `t3-fee050b4`) are not this
  coordinator's; leave them to the owner.

## Remaining 1.5.2 iOS items

1. **I8** docs/CI (last item before release).
2. **I5** device pass on the borrowed iPhone (ask the owner with notice):
   I9 checks, lock screen, Control Center, AirPods, interruptions, keychain
   second sign-in, the local network prompt (I2), VoiceOver wording and focus
   order (I18), Files-app behaviour (I14).
3. **I7** needs the paid Apple Developer Program.
4. I18 deferrals (ledger row): 44 pt below 340 dp rows (iPhone SE/mini keep
   40 pt), album link 37 pt at 2x, Android 48 dp, unlocalised Playback
   settings strings ("Saving changes…", "Changes save automatically").
5. Small findings to triage (unchanged): `tool/sync_diagnostics.sh` pre-run
   DB summary crash on macOS (`no such table: song_identity_aliases`); two
   `ping.view` errors at startup; end-of-sync state `partial`; do the
   diagnostics scripts find the iOS database in Application Support?
   Follow-ups from #350: failed-rebase retry of finished journals
   re-downloads instead of re-registering; copy fallback writes straight to
   final paths. Fixture handshake reports only a port, so `--bind` runs need a
   hand-built URL.

## Owner actions and questions (ask in one batch)

- A downloaded file deleted in the Files app is dropped from downloads at the
  next launch, not re-downloaded. Keep, or re-download?
- iPhone SE/mini keep 40 pt transport buttons (44 pt overflowed at 360 dp).
  Keep for 1.5.2 (coordinator's recommendation), or drop a quick action on
  narrow screens?
- Unchanged: paid Apple Developer Program; macOS hands-on pass; #266 and the
  desktop media-info dialog belong to the 1.5.2 session.
