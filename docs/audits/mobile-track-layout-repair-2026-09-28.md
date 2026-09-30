# Mobile track-layout repair — 2026-09-28

This correction follows the completed responsive overhaul and polish. Their
historical acceptance records remain unchanged. Automotive work remains in the
separate Polestar investigation.

> Note (2026-09-30): the Genre detail surface referenced below was removed by
> product decision; Genre rows in this record describe the state at the time
> of the audit, not current behavior.

## Regression and decision

The Android audit in `build/mobile-layout-audit/` confirmed oversized Liked,
album, reorderable playlist and full Artist Top Tracks rows. The shared row
reserved an eight-character duration column and moved controls below whenever
less than 160px remained for metadata. Ordinary phone widths consequently
produced roughly 112px Liked rows despite normal text size.

The accepted correction keeps Download and More beside the track. On crowded
mobile rows, duration uses its measured formatted width at the end of the
secondary metadata line. Metadata truncates first; duration, Remote provenance
and genuine badges may occupy additional lines inside the text block.
Controls move below only when the text area cannot retain 96 logical pixels
scaled by the text scaler. Those controls align to the trailing edge; duration
stays with the text, never beneath the artwork. Text and touch targets do not
shrink, and ordinary artwork rows have a 64px minimum height.

The existing AdaptiveContext chooses mobile presentation. Desktop column
geometry, headers, album fades, and mobile rows that already fit remain intact.
No data, playlist numbering/occurrence mapping, queue, filter, loading,
dependency, database, appearance or automotive behavior changes are intended.

## Caller audit

| Surface | Action-space contract |
| --- | --- |
| Liked / album / genre / full weekly detail | 96px, Download + More |
| Reorderable playlist | 144px, Download + More + drag handle |
| Filtered playlist | 96px; original occurrence callbacks retained |
| Artist preview | Explicit 96px for its two mobile buttons; previously estimated as 48px |
| Full Artist Top Tracks | Existing 82px rank/artwork area and 48px action; unavailable state retained |
| Downloaded tracks | 48px delete action and quality/size badge retained |
| Home ordinary tracks / Search | Existing zero-width mobile action area retained |
| Match Flow search | Existing artwork and action-free presentation retained |
| Recommendation rows | Existing 96px reservation and matching/unavailable/search behavior retained |

Genre's row and header now use the same AdaptiveContext decision. There is no
new Genre navigation entry.

## Regression coverage

The new mobile geometry suite explicitly supplies a non-desktop AdaptiveContext
at widths 320, 360, 390 and 448, scales 1.0/1.3/2.0, landscape 844×390, tablet,
and a wide non-desktop viewport. It rejects detached controls and oversized
ordinary rows, verifies 48×48 targets, duration appearing once in the text area,
trailing fallback controls, long and missing metadata, unknown/hour duration,
Remote provenance, selected state and badges. Existing desktop column/header
tests remain unchanged.

Populated page tests cover Liked, numbered album rows, filtered and reorderable
duplicate playlists, artist previews/full tracks, Genre, weekly matched and
unavailable recommendations, and downloaded tracks. Existing play/remove/reorder
occurrence checks, playback marker/download state checks, Home tests and compact
header hiding remain in the focused/full suites.

Intentional golden changes are the compact 390px shared row and the two mobile
album page goldens whose visible track rows changed. A new explicit mobile
390px row golden supplements geometry assertions. Desktop goldens retain their
starting bytes.

## Runtime evidence

The corrected source was built as the isolated Android profile sidecar
`com.navis.app.navis.mobilelayout`, version `1.4.0-sidecar`, on the owned API 37
emulator. `build/mobile-layout-repair/android-build-source.json` records the APK
hash and the runtime source hashes used for that build. No physical device was
used. The fixture server supplied four songs, an album, and a five-occurrence
playlist containing a duplicate song; artwork was intentionally absent.

App-owned, authenticated screenshots verified populated Liked, album,
reorderable playlist, full Artist Top Tracks, Home and Search rows at phone
widths 360/390 and landscape 844×390. Scrolled captures included actual song
rows. Android font scale 2.0 was inspected on Liked, album, playlist and Search.
Normal Liked rows returned to 64px, Download/More remained beside the text, and
the hour-long duration remained readable. Home, Search and fitting landscape
rows retained their existing inline duration treatment.

The real More control opened its menu; Download opened the quality chooser.
A touch drag through the mounted reorderable list persisted the expected
playlist order, including both duplicate occurrences. A subsequent clean
restart retained that order and its existing track-number values. Populated
downloaded tracks, Genre, resolved artist previews, weekly recommendations and
the other shared-row variants were verified through widget fixtures, rather
than claimed as populated Android runtime coverage. The full Artist Top Tracks
Android fixture exercised unavailable tracks and their Search actions.

Selected acceptance artifacts under `build/mobile-layout-repair/`:

- `liked-360-final.png`, `album-360-final.png`,
  `playlist-360-tall.png`, and `top-tracks-360-final.png`.
- `liked-390-scrolled.png`, `album-390-scrolled.png`,
  `home-phone-rows-final.png`, and `search-390.png`.
- The `*-landscape-final.png` captures, with
  `home-landscape-rows-final.png` supplying populated Home row evidence.
- `liked-text-200.png`, `album-text-200.png`, `playlist-text-200.png`,
  `search-text-200.png`, and `liked-download-quality.png`.
- `playlist-updates.jsonl` and `playlist-reordered-restart.png` for the
  successful drag and retained duplicate occurrences.
- All six `*-post-gate-restart.png` captures, inspected after the final gate.
  `clean-restart-proof.json` records different old/new process IDs.

An early fixture lacked the playlist mutation handler; its failed reorder
captures are excluded from acceptance. The fixture was corrected and the drag
repeated successfully. Empty captures taken before hydration are likewise
excluded from populated-row evidence.

The authenticated Linux clone smoke completed navigation, desktop screenshots,
log review and a clean restart in
`build/presentation-diagnostics/20260928T140757Z-clone`. Its initial and restart
captures retained desktop columns, controls and player timing. An initial
copied-profile sync-failure banner cleared after restart. Two earlier complete
responsive-polish loops also passed. A further optional native window work-area
scenario failed because the host reported a zero work area and no desktop
view; that scenario is not counted as passing and required no layout workaround.

Final Android and Linux logs contain zero layout/framework error markers,
recorded in `build/mobile-layout-repair/log-review.json`. The final focused
suite passed 201 tests; `./tool/check.sh` passed 1,762 tests, with one existing
skipped test. Logs are `focused-final.log` and `check-final.log` in the same
artifact directory. The final diff review verified that existing playback,
database and vendored changes retained their starting contents.

These build artifacts are local verification evidence, not committed app data.
Handshakes and credentials are not documentation artifacts. The isolated
emulator's display/font overrides, forwarding and fixture process are restored
or removed at handoff.
