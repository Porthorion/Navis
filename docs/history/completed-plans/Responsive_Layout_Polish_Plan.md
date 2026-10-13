# Responsive layout follow-up: album motion and headers

Date: 2026-09-28  
Status: completed; required local validation passed

This follows the completed responsive overhaul. Its original decisions and
evidence remain in [Responsive Layout Overhaul Plan](Responsive_Layout_Overhaul_Plan.md).
The follow-up baseline, including existing uncommitted work, is captured under
`build/responsive-polish/baseline/`. No database migration, new appearance
preference, dependency or automotive change is part of this work.

## Accepted behavior and implementation order

1. Desktop album opening and Back use the existing 180 ms composed-page fade.
   There is no opening artwork flight or page travel. Reduced motion is
   immediate. Navigation helpers omit the source Hero tag; the album route
   also enforces desktop fade for direct, replacement and legacy payloads.
   The detail page uses a distinct desktop artwork tag because Library cards
   otherwise match its fallback tag. Artwork-viewer Heroes remain available,
   and mobile/compact-landscape behavior and Back destinations are preserved.
2. `ContentShelf.showNextTooltip` defaults true and is false only for
   `liked-albums-shelf`. Its Next button keeps its localized accessible name,
   keyboard activation, focus, 48 px target and paging behavior. Previous and
   other shelves retain their visual tooltips.
3. `AdaptiveTrackHeader.numberColumnExtent` defaults null. Numeric headers
   display localized `#` with accessible description `Track number`, centered
   within the existing number slot. Album, playlist, genre and full ListenBrainz
   weekly collections use 32 px; full Artist Top Tracks uses the first 30 px
   of its 82 px rank/artwork area. No number values, occurrence identity or
   playback markers change. Artwork-only lists and compact header visibility
   remain as before.

## Acceptance gates

| Gate | Required checks | Result |
|---|---|---|
| Album motion | Timed forward/reverse fade, direct/legacy requests, reduced motion, helper payloads, mobile landscape and Back regressions, distinct viewer Hero | Passed: 61 tests, one existing skip |
| Shelf tooltip | Real hover, accessible name, keyboard/click paging, defaults elsewhere, Liked-only caller | Passed: 50 tests |
| Number header | Numeric/artwork-only visibility, 32/30 px alignment, medium/wide/compact and scaled text, caller coverage, relevant goldens | Passed: 10 shared-widget tests; 86 caller/occurrence tests, one existing skip |
| Final acceptance | Generated localization, focused tests, full quality gate, authenticated Linux navigation/paging/screenshots/logs and clean restart, diff/document review | Passed |

Active navigation/adaptive architecture and both release-note sources were
updated with the implementation. This follow-up is archived after its required
local gates passed. Previous overhaul validation is not substituted for
evidence of these new changes.

## Execution evidence

- `flutter gen-l10n` regenerated the tracked English localization output.
- Focused transition, shelf, header and caller checks passed in the order
  above. Diagnostics controller/API tests passed (40 tests); the final API
  fixture lifecycle correction passed its 36-test server group too.
- `./tool/check.sh` passed formatting, code generation, analysis, critical
  reliability/migration checks and the full suite: 1,698 passed, one existing
  skip. The first full run caught overlapping database fixtures in a new
  diagnostics test. Closing the first fixture before opening the second
  resolved the warning; no warning suppression or gate weakening was used.
- Two number-header goldens were added and visually inspected. The existing
  compact desktop album golden changes only the expected number heading;
  its title, actions and first tracks retain their positions. The changed
  image was inspected and the focused caller suite rerun after the update.
- Navigation/header architecture, diagnostics development/CI instructions and
  both user-facing release-note sources have been updated.
- Logs and task-scoped comparison with the captured baseline are under
  `build/responsive-polish/`. The original completed overhaul and separate
  Polestar investigation remain byte-for-byte unchanged.
- Authenticated Linux clone runtime passed at
  `build/presentation-diagnostics/20260928T103037Z-clone/`. Both launches
  exercised the real Albums-card callback and a Liked album callback, producing
  the expected album-detail routes. Scoped Next paging visibly advances the
  Liked Albums shelf. All 14 app-owned screenshots were opened and inspected:
  wide numeric headings align, minimum-size compact headers remain hidden,
  and returning to Liked retains its overlay labels and artwork-only headings.
- Both launches shut down through the authenticated API and restarted cleanly.
  `log-errors.txt` is empty. Existing AT-SPI bus and MPV file-cache notices also
  appear in the earlier `20260928T092134Z-clone` baseline; there are no Flutter
  exceptions, provider-build mutations or duplicate-database warnings.
- `git diff --check` and the presentation runner's shell syntax check passed.
  The task-only diff was reviewed against the captured initial worktree.

## Runtime verification support

The authenticated diagnostics API previously supported route navigation and
vertical scrolling but could not activate an album card or the horizontal
Liked Albums Next button. The narrow clone-only `library-action` endpoint now
invokes those existing UI callbacks, with no arbitrary control identifiers or
coordinates accepted. Authentication, invalid payloads, offstage/unrelated
controls and primary-profile rejection have regression coverage. The
`responsive-polish` runtime scenario exercises both callbacks and captures
numbered album rows at wide and minimum desktop sizes on both launches.
This support changes neither playback ownership nor library persistence.

Settled runtime screenshots establish layout and navigation outcomes. Timed
widget tests establish the 180 ms forward/reverse animation, reduced motion
and absence of page travel; screenshots are not animation timing evidence.

## Handoff and coverage limits

Implementation, localization, documentation and required local gates are
complete. No new appearance setting, dependency, database migration or
automotive change was introduced. Mobile transition regressions ran in widget
tests; this follow-up did not repeat Android device/emulator runtime or run
Windows/macOS/iOS builds. Those limits do not replace the earlier overhaul's
separate evidence. Existing uncommitted work remains intact; this follow-up
does not create a commit or publish a release.
