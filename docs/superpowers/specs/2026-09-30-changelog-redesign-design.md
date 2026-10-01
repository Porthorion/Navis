# Changelog redesign — design

- Date: 2026-09-30
- Status: approved

## Context

The changelog has outgrown both of its surfaces.

- **Settings → About → Changelog** (`lib/src/features/changelog/presentation/changelog_screen.dart`) is a single flat `ListView`: about 430 paragraph-length entries across 30 versions.
  - 1.4.0 has 90 entries (10 new, 41 improved, 39 fixed) and 1.2.5 has 108, yet both get the same small "Version x" header as a one-fix patch.
  - Fixes are tinted with `colorScheme.error`, so the page reads red.
  - There are no dates, no grouping, no collapsing and no desktop layout.
  - "Version x" and the Fix/Improved/New labels are hard-coded English.
- **The Home discovery card** (`_ChangelogDiscoveryCard` in `lib/src/features/home/presentation/home_support_widgets.dart:223`) previews the *first* non-fix entry. For 1.4.0 that is a perf sentence about artist shuffling, not the release's story.
- **Debt:**
  - `changelog_dialog.dart` is dead code; only its test calls it.
  - `tool/generate_release_notes.dart` keeps an 1,800-line hand-synced copy of the data, with no check that the copies match.

Intended outcome:

- Every x.y.0 release gets a curated hero banner: an optional codename ("Navi"), an optional custom icon centred in the banner (sparkles fallback), date, counts and 3–5 highlight cards.
- Entries are grouped New / Improved / Fixed, with fixes collapsed and calmer.
- Older releases sit in a compact, expandable timeline, with a two-pane layout on desktop.
- Home shows a compact "Check out 1.4 “Navi”" card with highlight badges and no description. It stays inline (non-blocking, per design-ux-audit D5).
- One source of truth feeds both the app and the release notes.

User decisions:

- A major release is every `x.y.0`.
- Highlights are curated; auto-derivation is only the fallback.
- Home uses the richer inline card.
- All three cleanups are included: delete the dialog, de-duplicate the generator, localize the labels.

## 1. Data model (`lib/src/features/changelog/changelog_data.dart`)

The file must stay pure Dart with **no imports**, so the generator can import it directly (step 5).

- `ChangelogVersion` gains:
  - `String? released`: ISO `YYYY-MM-DD`, parsed in presentation, not stored as a const `DateTime`.
  - `String? codename`: the release's name, e.g. `'Navi'`. It replaces a separate "headline".
  - `String? iconAsset`: optional path to a bundled SVG or PNG, e.g. `assets/changelog/navi.svg`.
    - When it is null, the file is missing, or the image fails to load, the UI falls back to `Icons.auto_awesome` (sparkles).
    - SVG renders via the existing `flutter_svg` dependency; PNG via `Image.asset`.
    - Declare `assets/changelog/` in `pubspec.yaml`.
  - `String? summary`: optional, shown only in the Settings hero, never on Home.
  - `List<ChangelogHighlight> highlights = const []`
- Computed getters on `ChangelogVersion`:
  - `bool get isMajor`: patch component == 0 (parse `x.y.z`, tolerant of malformed input → false).
  - `String get displayVersion`: `1.4` for majors, `1.4.1` otherwise.
  - `int countOf(ChangelogEntryType)`
- New `class ChangelogHighlight { const ChangelogHighlight({required this.icon, required this.title, required this.body}); final ChangelogHighlightIcon icon; ... }`.
- New `enum ChangelogHighlightIcon`: a small curated set such as `equalizer, speed, headphones, performance, search, library, sync, desktop, player, download, sparkle`. It maps to `IconData` in presentation, so the data file has no Flutter import.
- Backfill `released` from `git tag --sort=-creatordate` (v1.3.1 = 2026-08-26 … v1.0.x). Leave versions without a tag `null`. Set 1.4.0's date at release time; until then it stays `null` and no date is shown.
- Author the codename, highlights and optional summary for **1.4.0, 1.3.0 and 1.2.0** (drafts for the user to edit; the user supplies any custom icons):
  - **1.4.0:** codename "Navi" (user's choice). Highlights:
    - Equalizer (live graph, AutoEQ import)
    - Speed and pitch (presets, Pitch Lock)
    - Quick panels in the player
    - Faster with big libraries
    - Search in every script
  - **1.3.0:** codename to be chosen by the user (no codename → the card reads "Check out 1.3"). Highlights:
    - Setup flow
    - Repair vs. rebuild
    - Vorbis transcoding
    - Sync history
  - **1.2.0:** codename to be chosen by the user. Highlights:
    - Desktop View and Mini Player
    - Guided first sync
    - Now-playing highlight everywhere
    - Volume memory
- Fallback when a major has no curated highlights: use the first ≤3 `newFeature` entries, with the text truncated in the UI.

## 2. Shared presentation pieces (`lib/src/features/changelog/presentation/`)

Split into focused files; all use `NavisSpace`, `NavisRadius`, `TextTheme` slots and `ColorScheme` roles, with no new literals (the token guard enforces this).

- `changelog_style.dart`: `entryIcon` / `entryColor` / `entryLabel(l10n)` move here from `changelog_entry_tile.dart` and `highlightIcon(ChangelogHighlightIcon)` is added. Colours:
  - New → `primary`
  - Improved → `secondary`
  - Fixed → `onSurfaceVariant` (no longer `error`)
- `changelog_release_icon.dart`: `ChangelogReleaseIcon(version, size)`.
  - Renders the `iconAsset` inside a circular disc tinted with `primary`.
  - Falls back to the sparkles icon when there is no asset or it fails to load (`errorBuilder` / SVG error handling).
  - Used by both the hero and the Home card.
- `changelog_release_hero.dart`: `ChangelogReleaseHero(version)`, the major banner, **centre-aligned**:
  - A `surfaceContainerHigh` card tinted by a diagonal `primary`→`tertiary` wash (20% → 10%) with a faint `primary` border and `NavisRadius.xl`. Text uses `onSurface` / `onSurfaceVariant`. (Runtime check: the first `primaryContainer` gradient was unreadable with a monochrome seed, whose `onPrimaryContainer` stays mid-grey.)
  - The top row holds a "Major release" pill and the date.
  - Centred below it:
    - the release icon (about 72 dp disc);
    - "Version 1.4" in `labelLarge`;
    - the codename in `headlineMedium` (or the version alone in `displaySmall` when there is no codename);
    - the optional summary (`bodyMedium`, ≤2 lines);
    - count chips ("10 new · 41 improved · 39 fixed", ICU plurals).
- `changelog_highlight_card.dart`: one highlight card (icon, title, one line) on a `surfaceContainerHigh` tile. The strip scrolls horizontally on phones and becomes a grid (`Wrap`/`GridView`, 2–3 columns) on desktop.
- `changelog_release_details.dart`: `ChangelogReleaseDetails(version)`, a `StatefulWidget` holding local UI state.
  - Filter chips: All / New / Improved / Fixed. A chip is shown only when its type has entries.
  - Sections per type, each headed "New · 10" and using the existing `NavisSectionHeader` (`common_widgets/navis_section_header.dart`) if its compact mode fits.
  - Entries are rendered by the rewritten `ChangelogEntryTile`: a thin type-coloured leading rule plus `bodyMedium` text, with the per-row label removed because the section names the type.
  - The Fixed section shows the first 5 plus "Show all 39 fixes", which expands in place and animates via `MotionPolicy`.
  - Special Thanks follows as a quiet `surfaceContainerLow` card.
- `changelog_timeline_tile.dart`: a collapsed row with a rail dot (larger and accent-coloured for majors), version, date, codename (majors only) and total count. It expands to `ChangelogReleaseDetails`, preceded by a compact hero for majors.

## 3. Changelog screen (`changelog_screen.dart`, route unchanged `/settings/about/changelog`)

- **Phone / narrow:**
  - The current release comes first:
    - a major gets the hero, highlights and details;
    - a patch gets a compact header (version, date, counts) and details.
  - If the current release is a patch, its parent major also appears as a pinned "Part of 1.4 “Navi”" row.
  - Then an "Earlier releases" header and one `ChangelogTimelineTile` per remaining version.
  - Uses a lazy `ListView.builder`/slivers, not the eager list of every tile.
- **Desktop** (`resolveAdaptiveContextFor(context).useDesktopShell`), following `AboutScreen`'s desktop back button and frame (`about_screen.dart:72-85`):
  - A left rail lists versions, with majors labelled and indented patches beneath them.
  - The right pane shows the hero (majors), highlights grid and details for the selected version.
  - Selection is local state and defaults to the newest version.
- The optional `?version=1.4.0` query param preselects or expands a version; the Home card uses it. Add it to `NavService.openAboutChangelog` (`routing/navigation_service.dart:277`) as an optional argument.

## 4. Home card (`_ChangelogDiscoveryCard`)

- `changelogToShowProvider` (`changelog_provider.dart`) now returns a small record `ChangelogDiscovery({current, featured})`:
  - `featured` is the newest *major* in the unseen range (lastSeen, current], so a user jumping from 1.3.1 → 1.4.1 still sees the 1.4 “Navi” card.
  - The seen-file mechanics are unchanged.
- **Major (or featured major):** a compact, **description-free** card.
  - Row 1:
    - the release icon (36–40 dp; custom or sparkles fallback);
    - the title "Check out 1.4 “Navi”" (`titleMedium`); without a codename, "Check out 1.4";
    - a dismiss button.
  - Row 2: up to 3 highlight badges (icon + title) plus a "+N" chip when there are more. They come from curated highlights, else from the first `newFeature` titles, else from the counts.
  - The whole card is tappable (InkWell, same `changelogDiscoveryOpen` key). It opens `/settings/about/changelog?version=1.4.0` and marks the version seen.
  - A `primary` border at low alpha, and no summary text, so the card is about two rows tall.
- **Patch only:**
  - A compact single-row card: "Updated to 1.4.1 · 3 fixes · 1 improvement" with a chevron.
  - It replaces the "first entry" preview.
- Existing keys `changelogDiscoveryOpen` / `changelogDiscoveryDismiss` and the semantics label are kept. The card must still work at 200 % text scale (existing test).

## 5. Single source for release notes (`tool/generate_release_notes.dart`)

- Delete the inline model and `_changelogs` copy. `import '../lib/src/features/changelog/changelog_data.dart';` works because the data file has no imports.
- Extract `String renderReleaseNotes(ChangelogVersion v)`:
  - `## What's New in Navis vX “Codename”`, then the summary and a `### Highlights` list when present.
  - The icon is app-only and not emitted.
  - This markdown is what users on **older** app versions see in their in-app update dialog: `update_dialog.dart:208-220` renders the Forgejo release body with a Markdown widget. So keep to plain headings and lists.
  - Then `### New` / `### Improved` / `### Fixed` sections, then Special Thanks.
- Keep the CLI contract: exit codes 0/1/2, and stdout consumed by `tool/release.sh:786-795`.
- Update the "not found" message to name only `changelog_data.dart`.

## 6. Cleanup and localization

- Delete `lib/src/features/changelog/changelog_dialog.dart` and `test/src/features/changelog/changelog_dialog_test.dart`.
- Remove the now-unused `changelogDialog*` / `whatsNewTitle` keys from `lib/l10n/app_en.arb` after grepping for other users.
- Add l10n keys:
  - version label
  - Major release
  - New / Improved / Fixed
  - count plurals
  - Show all {n} fixes
  - Earlier releases
  - Part of {version}
  - Updated to {version}
  - See what's new
- Regenerate `app_localizations*.dart` via the repo's normal gen step.
- Lower `test/src/theme/design_token_baseline.json` for `changelog_entry_tile.dart` (radius 1 → 0) and remove any entry for deleted files.

## 7. Documentation and changelog

- Update the rule "entries in both `changelog_data.dart` and `tool/generate_release_notes.dart`" to name only `changelog_data.dart` in:
  - `AGENTS.md` (l.64–66 and the ownership table)
  - `docs/agentic-engineering.md` (l.51–53)
  - `DEVELOPMENT_PLAN.md` rule 24 (l.3082–3097), which also gains how to write `codename`/`iconAsset`/`summary`/`highlights` for x.y.0 releases and `released` dates
- `docs/architecture.md`: add a short "Changelog" subsection (data model, major rule, Home discovery range, screen layouts, generator import).
- `docs/audits/ux-ui-audit-2026-09-30.md`: add a "Changelog redesign" follow-up section like the You Might Like one.
- `docs/history/removed-features.md`: record removal of the unused What's New dialog.
- Add a 1.4.0 `ChangelogEntry` (improvement) describing the redesigned changelog and Home card.

## Compatibility (users not yet on 1.4.0)

- **Their changelog is unaffected.** Changelog data and UI are compiled into each app build (a `const` list), so older installs keep their own screen and content until they update.
- **No stored format changes.** The seen-marker is still a plain version string in `changelog_seen_version.txt`. After updating, the new app reads the old marker (e.g. `1.3.1`), sees that it differs from `1.4.0`, and shows the card once.
- **Before updating,** those users see only the release notes markdown in the update dialog. The new generator output (codename, highlights, New/Improved/Fixed sections) is plain Markdown, which that dialog already renders.
- **Downgrades** are harmless: an older build reading a newer marker just shows no card.

## 8. Tests

- `test/src/features/changelog/changelog_data_test.dart`:
  - `isMajor` and `displayVersion` parsing
  - counts
  - every major version from 1.2.0 onward has 3–5 highlights (codename optional)
  - every non-null `iconAsset` exists on disk and sits under a declared asset directory
  - versions are unique and in descending order
  - `released` parses when present
- `test/src/features/changelog/changelog_screen_test.dart`:
  - hero shown for a major, not for a patch
  - filter chips filter
  - "Show all fixes" expands
  - timeline tile expands
  - desktop two-pane selection
  - golden for phone major, phone patch and desktop, in light and dark
- `test/src/features/changelog/changelog_provider_test.dart`: the featured-major range logic (1.3.1→1.4.1 features 1.4.0; same-major patch has no featured major; lastSeen == current returns null).
- `home_screen_test.dart` (~l.859/905): update the override shape, regenerate `goldens/home_changelog_discovery_card.png`, and add a patch-card golden.
- `test/tool/generate_release_notes_test.dart`: render 1.4.0 and assert its sections; run the CLI with an unknown version and assert exit code 2.
- Release-icon widget: sparkles fallback for a null asset and for a missing asset.
- Home card: "Check out 1.4 “Navi”" title, no summary text, and the badge "+N" overflow.

## Verification

1. Focused tests:

   ```bash
   flutter test test/src/features/changelog test/src/features/home/presentation/home_screen_test.dart test/src/theme test/tool
   ```

   Then `dart tool/generate_release_notes.dart v1.4.0` and inspect the markdown.
2. `make gen` if l10n generation requires it; then `flutter analyze --no-fatal-infos`, and `./tool/check.sh` (required).
3. Runtime loop per `docs/development-workflow.md`:
   - Use an isolated clone profile.
   - Delete the clone's `changelog_seen_version.txt` to surface the Home card.
   - `POST /v1/presentation/navigate` to `/` and to `/settings/about/changelog`.
   - `POST /v1/presentation/screenshot` at phone and desktop sizes.
   - Use the `/v1/presentation/appearance` endpoint for light, dark and OLED.
   - Inspect the PNGs: hero legibility, chip wrapping at 360 dp, the desktop two-pane layout, and the Home card height.
   - Dismiss, then clean restart, and confirm the card stays dismissed.
4. Review the full diff. Commit the goldens in their own commit, per the design-foundation decision.

## Addendum (2026-10-01): superseded presentation

The data model, provider range logic, single-source release notes and Home
discovery behaviour above still apply. The presentation (centred hero,
highlight cards, chips, sparkles fallback, timeline) was replaced by an
album-style layout after a review against AI-generated-UI tells. See
`docs/architecture.md` → *Changelog and What's New* and the audit's
"Follow-up: removing the generic look".

