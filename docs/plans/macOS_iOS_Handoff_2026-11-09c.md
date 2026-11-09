# macOS/iOS coordinator hand-off, 2026-11-09 (c)

Replaces [the 2026-11-09 (b) hand-off](macOS_iOS_Handoff_2026-11-09b.md).
Ledger: [iOS_Parity_Plan.md](iOS_Parity_Plan.md) (I32, I33). Rolled over
after three item PRs merged (#451, #453, #455).

## State

- #450 (forward of #449 plus hand-off b) merged to `dev` (`9d1f1e8d`); ledger
  rows I32/I33 added in #452.
- Owner approved the 1.5.2 triage on 2026-11-09: I32 (#410 follow-ups a-e)
  and I33 (grid restore by item index).
- **Merged on `release/1.5`, forwarded to `dev` by the PR carrying this
  hand-off:**
  - #451 I32e: album Play row at 16 pt when the page (its LayoutBuilder
    width, not the window) is at least 375 pt wide, else 4 pt. Goldens
    `album_detail_mobile_title_after` and `..._text_scale_200_after`
    regenerated from CI's Linux renders.
  - #453 I32c: HTML entities decoded in the API models (`Album.name/artist`,
    `Song.title/album/artist`, `Artist.name`, `ArtistRef.name`, genres) via
    `lib/src/utils/html_entities.dart`. Cause proven on the server: the
    Krewella album tag holds `&amp;`. No forced resync: stored names fix on a
    full repair (a normal sync can carry encoded song titles forward).
  - #455 I32d: vendored just_audio keeps the current `updateTime` when an
    event has the same position and item but an older stamp (stale native
    stamp after a paused-ready load made Android extrapolate ~load time at
    stream start). Code trace only, not reproduced at runtime.
- **Open:** #454 I33 (grid scroll anchor in `ResponsiveContentSliverGrid`,
  wired in `library_screen.dart`). Fresh Sonnet review: one blocking finding
  (header scrolled away at the top on a fold) fixed in `2938d1ea` with two
  smaller items. CI was running at rollover. Merge (squash) on fully green CI;
  no further review needed unless CI fails on logic.
- Open PRs not ours: #414 (1.6 live-mode design, other machine).

## Owner actions

- I5 device-pass results from TestFlight 1.5.2 (37437428): owner has not
  tested yet.
- No `dev` TestFlight build: owner has no real iPhone Duo; simulator runs are
  accepted for I28/I29 and foldable work.

## Next steps

1. Merge #454 on green CI, delete its branch/worktree
   (`~/.t3/worktrees/Navis/t3-2225be02-d0a9d736972bc350`), forward to `dev`.
2. One batch runtime pass (a delegate, one heavy job at a time on this 8 GB
   Mac) covering: I32a iPad portrait Now Playing (controls on screen), I32b
   unfolded Duo portrait 669x951, I32e folded Duo album Play row at 16 pt,
   I33 Duo fold/unfold on Albums and Artists (also at the top), I32c the
   Krewella album title after a full repair, I32d Android emulator
   direct-stream start (no forward jump; if a `backwardJump` still shows,
   check the `pb` rows: the stale event's `updatePosition` must equal the
   current one exactly for the fix to engage). Evidence under `build/152-runtime/`.
3. Then wait for the owner (I5 results).

## Notes learned

- CI goldens are Linux renders; macOS local runs show ~8 platform golden
  diffs in `library_detail_screens_test.dart`. To regenerate, temporarily add
  an `actions/upload-artifact` step (`if: failure()`, path
  `test/**/failures/`) after the test step, download with `gh run download`,
  check the `_testImage.png` files by eye, copy them over the goldens, and
  revert the CI step in the same PR.
- A CI run once came up without the `tooling` job; `gh run rerun --failed`
  only reruns `ci`. Use a full `gh run rerun <id>`.
- Local test failures on `release/1.5` in `mediakit_replay_gain_test.dart`
  (14) and `navis_audio_handler_navigation_test.dart` (16) are macOS-local;
  CI is green.

## Worktrees and branches

- `merge/rel15-dev-152` in `../Navis-wt-fwd2` (this forward PR): delete after
  merge.
- `fix/152-grid-index-restore` (#454) in the T3 worktree above.
