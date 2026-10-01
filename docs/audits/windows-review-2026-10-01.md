# Windows review follow-up (2026-10-01)

Branch `fix/windows-review` (34 commits on top of `dev` at `d0ed2248`). This
records what was changed after the Windows review of the 1.4.0 work, how it
was verified, and what still needs a decision.

## What changed

**Playback**

- Shuffle is owned by Navis (schema v88 saves the unshuffled order). The
  desktop bug it fixes was confirmed first: media_kit's `playlist-shuffle`
  reorders mpv's playlist behind just_audio, so the song reported as playing
  was not the song heard.
- Played songs are released from the player into a deferred head. Far jumps
  materialise only a window around the target and keep the old queue when the
  target cannot load.
- A queue edit whose native call times out reloads the queue into the rebuilt
  player. Single removals and moves are timed too.
- A seek served from a completed sidecar file keeps the whole queue (it used
  to drop every other song).
- Remote rows keep their own row through re-deferral, far jumps, seek
  recovery and crossfade deck sync.
- Queue edits apply in the order they were made. An edit a replacement
  discards reports `OperationCancelledException`. Restore and seek-recovery
  fills no longer cancel commands.
- Dropped songs are reported (`droppedSongsStream`), and artist queues keep
  them visible as unavailable.
- Speed and pitch changes rebuild the audio graph once. Lane drain and range
  removal are hardened, repeat is restored after a seek, and radio refills are
  cached.

**Downloads**

- Downloads are written as `<name>.navis-part` and renamed into place.
- The download service starts at launch, so interrupted downloads resume.
- A server-data reset keeps files in a user-chosen folder.
- Folder paths are compared by key (links, junctions, case on Windows), and a
  file is never moved onto itself.
- File names are Windows-safe, scans skip unreadable entries, and the recorded
  size is re-read after tagging.

**Sync and database**

- A characterization golden for promotion after an id rebuild.
- C1: the MBID index is built once per reconciliation pass.
- C2: cache files a rolled-back promotion remapped are kept.
- C3: stale id sets of any size are handled.
- C4: the artist index is never refreshed inside the snapshot transaction.
- Stale-only preservation: current artists and songs are no longer marked
  provisional after a rebuild.
- C5 was measured only.

**Other**

- EQ presets import from Equalizer APO, REW, EasyEffects, AutoEQ GraphicEQ,
  ParametricEQ, FixedBandEQ and Navis files, in any text encoding or decimal
  separator.
- Desktop shelves scroll by mouse drag.
- One You Might Like page controller is kept across width changes.
- Home metadata and onboarding errors are localized.
- The Windows SMTC diagnostics script runs on Windows PowerShell.

## Verification

| Where | What | Result |
| --- | --- | --- |
| Linux | `./tool/check.sh` after every batch | Passed; the last run covered the final code (2,163 tests, 1 skipped). |
| Linux | Queue window model test: 500 seeded random sequences of navigation, auto-advance, edits and shuffle | Passed; a planted head-offset bug fails at seed 0. |
| Linux profile | `tool/shuffle_parity_diagnostics.py`: shuffle parity plus a 2,000-song window | 0 of 32 samples disagree. The native playlist held 33 to 98 songs. |
| Linux profile | Home screenshot; EQ on with three speed and pitch changes | Rendered correctly. Playback stayed ready with EQ applied and no filter errors. |
| Linux profile | Download killed mid-transfer in a user folder, restart, reset | Only the part file existed after the kill. The restart resumed it under its final name without any UI action. Reset left all six user-folder files. |
| Windows 11 VM | Shuffle parity and the 2,000-song window through the diagnostics API | 17 of 17 samples passed (native playlist 33 to 101 songs). |
| Windows 11 VM | Download killed mid-transfer in a user folder, restart, reset | Only `Track 09.wav.navis-part` existed after the kill. The restart completed `Track 09.wav` at full size with no `[hash]` copy. Reset kept every user file. |
| Windows 11 VM | `tool/windows_smtc_diagnostics.ps1` | Passed. |
| Android 37 emulator (disposable AVD) | Shuffle on and off, force-stop, restore | Shuffle keeps the current song and the native player never shuffles. The saved shuffled order restores and unshuffles to the original position. |
| Real server, isolated clones | `sync_diagnostics.sh` throughput, cache-alias and clone; `repair_confirmation_diagnostics.sh` | Passed. Throughput was within network variance of the baseline. |
| Real server | `sync_target_lane_diagnostics.sh` | Failed, identically on the commit before the sync changes (pre-existing; see below). |

## Decisions for the product owner

Decisions 1 to 3 were taken and implemented the same day: EQ on Windows with a
pinned full libmpv, the indexed track-match lookup, and same-sync rebuild
matching. Results are in `docs/sync-stability-validation.md`, the Windows
section below, and `docs/release-windows.md#bundled-libmpv`.

1. **Windows EQ.** The media_kit libmpv builds lack ffmpeg audio filters. A
   full libmpv build (shinchiro 2026-09-28) runs the Navis filter chain but
   installs 115.2 MB instead of 14.8 MB (about 26 MB more to download).
   Options:
   - accept that size;
   - build a slim libmpv with only the audio filters Navis uses;
   - keep EQ unavailable on Windows.
   Nothing was changed.
2. **Track matching (C5).** On the 57,318-song library, matching 50 tracks
   takes 450 to 550 ms, and 448 ms of that is the artist containment scan. An
   indexed rewrite gave nothing. A real gain needs an indexed artist-key table
   (a schema change) and narrower token matching, which also returns far fewer
   candidates (13,800 to 18,700 for 50 tracks today).
3. **MBID aliasing after a rebuild.** Songs of a rebuilt album whose download
   was preserved become provisional, and they are aliased to their new ids
   (by recording MBID) only on the next full sync. Aliasing them in the same
   promotion would need a second reconciliation pass.
4. **Lane cancellation.** A superseded queue command still settles
   immediately, while its blocked native call finishes in the background. This
   is kept because the lane tests require it.

## Pre-existing issues found (tracked as separate tasks)

- After a restart, an automatic delta sync that ends partial on its time or
  entity budget leaves no next automatic check or retry. Sync Settings then
  shows "Scheduling…". Reproduced on the commit before these changes.
  **Fixed afterwards:** the run was the cloned profile's interrupted Check for
  updates (durable origin `libraryPullToRefresh`) resuming before the future
  deadline, not the automatic schedule. The persisted automatic deadline was
  intact; the controller dropped it from status because engine progress and
  results never carry it. Status now reloads both deadlines from the persisted
  row after every catalog run. The cleared retry is correct, because a
  budget-limited partial is a successful check that closes the failure
  circuit, so the target-lane gate now checks the retry against that rule.
- On an Android cold start where the session is not ready yet, the queue
  restore is deferred (`deferred_auth`) and only retried when Play is pressed.

## Windows EQ verification (after the decision)

On the Windows 11 VM at `bb4f0de6`, with the bundled 20261001 libmpv:

- A standalone libmpv probe built the exact Navis chain
  (`@navis_tempo:scaletempo`, `@navis_eq:lavfi=[volume,biquad…]`) and played
  audio. The old 2023 DLL failed on the same chain.
- In the app, through the diagnostics API: EQ is reported supported, and 14 of
  14 checks passed with EQ applied and playback running. The checks covered
  the Simple gains with preamp, the Bass and Vocal presets, 10-band, Advanced
  (shelves, peaking, notch, high- and low-pass), four speed and pitch pairs,
  a seek, automatic and manual track changes, and EQ off and back on. EQ
  persisted across a restart and applied again on the next song.
- Queue and shuffle parity with the 2,000-song window passed 17 of 17. A first
  attempt timed out waiting at the 1,000 jump although the player had reached
  it; the traced rerun passed every step.
- `tool/windows_smtc_diagnostics.ps1` passed. EQ page screenshots were
  inspected (Advanced and Bass boost, both applied).
- HTTPS: a valid certificate streamed, and an expired one was refused.
- The fixture streams at 22.05 kHz could not represent filters above
  11 kHz, and Navis correctly reported that; the checks above used 44.1 kHz.

## Environment notes

- A fresh download of the `sqlite3` 3.5.2 native library
  (`libsqlite3.x64.linux.so`) fails its pinned hash: it gets `839488eb…`
  instead of `b1772918…`. Existing verified copies still work. Treat this as a
  supply-chain signal before the next dependency update.
- The Windows VM has about 3 GB free on each of C: and S:.
