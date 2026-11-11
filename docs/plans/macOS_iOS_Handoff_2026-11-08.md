# macOS/iOS coordinator hand-off, 2026-11-08

Previous: [2026-11-07f](macOS_iOS_Handoff_2026-11-07f.md). Ledger:
[iOS_Parity_Plan.md](iOS_Parity_Plan.md).

## State

- `dev` = `c80fe07f` (I23 merged). This session merged #364, #370 (I7
  TestFlight path), #379 (I22 sideload IPA) and #381 (I23 gapless).
- TestFlight: build 37332319 (from `e3a3fc73`) uploaded and processed,
  "Ready to Submit". Internal testing only; external testing waits on the
  owner's demo server.
- The owner is setting up the demo server (Navidrome at
  `https://navis.porthorion.com/demo` or a subdomain) in a separate Opus
  coordinator; not this thread's work. Check whether Navis keeps a base-URL
  path (`/demo`) when that coordinator asks.
- Upload credentials: `tool/release.env` (git-ignored, mode 600) and the
  key under `~/.appstoreconnect/private_keys/`. Never print them. Upload:
  `tool/release.sh` with `--ios-upload` (see `docs/release/release-ios.md`).

## Next steps, in order

1. **I21 pitch** (risky, 1.5.2): plan on branch `ios-i10-pitch-probe`
   (`cbd554d7`, `docs/plans/iOS_I10_Pitch_Plan.md`, now `iOS_I21_Pitch_Plan.md`, worktree
   `.claude/worktrees/agent-afcd8b1080ce08476`). Before briefing Sonnet,
   update the plan to the merged I23 design: one shared tap per player and a
   flush counter (`noteFlush` at the top of `seek:index:` and in `load:`),
   not "a time-range jump means reset". Also: every seek/skip re-prepares the
   tap (I23 measurement), and the gap meter only runs in diagnostics builds.
   Build with Sonnet high in a worktree on fresh `origin/dev`, fresh Sonnet
   plus Opus review, simulator proof (pitch audible, gapless still ~0 ms with
   pitch on, lock-to-speed), CI, merge.
2. **I24 ReplayGain boost on iOS**: proposed for 1.5.2 after I21; the owner
   was told it goes ahead unless they move it to 1.6. Needs an Opus plan
   (gain stage in the shared tap, reuse the margin and guard-window rules
   in `navis_playback_rules.dart`).
3. **Builds once I21 (and I24 if quick) land** (owner 2026-11-08): from one
   `dev` commit, the macOS dev app signed with the Apple Development cert
   (Team BFBNSCVKXH), then a TestFlight internal build via
   `--ios-upload`. One heavy job at a time. Tell the owner when processing
   finishes so they add it to the internal group; that build is also the I5
   device pass (borrowed iPhone).
4. Ledger nits: CarPlay is 2.0.0 in `development-plan.md` but 1.6 in newer
   docs; note Mac App Store updater gating plus sandbox as a future macOS item.

## Parity survey 2026-11-08 (Flash, verified by Opus)

Shared with no gate: lyrics, scrobbling, Same Vibes, offline, cache and
downloads, ReplayGain modes, speed, haptics. iOS gaps all have items (I5,
I16, I19, I20, I21, I22, I4 deliberate) except: ReplayGain boost (now I24),
native "Restart Navis" (Android-only `MainActivity.kt:134`; deliberate, iOS
cannot relaunch itself) and Ogg/Opus cut splicing (Android-only,
`playback_source_resolver.dart:455`; probably moot since iOS does not request
Opus; confirm the iOS transcode format before adding an item).

## Known limits from I23

"Play next" mid-song stalls the playing song ~0.8 s (pipeline rebuild; also
seen on dev before I23). An audio track ID other than 1 plays without EQ
when tracks are not yet loaded (documented in `equalizer.md`). HLS untested.

## CI

GitHub release downloads returned 503 on 2026-11-08 for ~1 h; every job
failed at the sqlite3 native-asset hash check (`Hash of downloaded file ...
bef140a1...`). Re-running failed jobs after recovery fixed it. If it
recurs, check `curl -sL -o /dev/null -w '%{http_code}'` on the sqlite3
release asset before debugging.

## Worktrees and branches

- Kept: `.claude/worktrees/agent-afcd8b1080ce08476` (`ios-i10-pitch-probe`,
  I21 plan).
- Deleted: the I23 build and investigation worktrees and branches.
- Not ours, leave: `~/.t3/worktrees/Navis/t3-*`, `worktree-agent-a55df5d382acdd0f4`.

## Owner actions open

- Demo server (in progress, separate coordinator), then the Beta App Review
  sign-in in App Store Connect.
- Add build(s) to the internal tester group when told.
